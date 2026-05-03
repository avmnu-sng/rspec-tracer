# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

require 'rspec_tracer/cli/doctor'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::CLI::Doctor do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer doctor')
      end
    end

    it 'prints checklist with OK lines for ruby + tracer + paths in a healthy project' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      lines = stdout.string.split("\n")
      expect(lines.any? { |l| l.start_with?('OK   ruby:') }).to be(true)
      expect(lines.any? { |l| l.start_with?('OK   rspec-tracer:') }).to be(true)
      expect(lines.any? { |l| l.include?('cache_path:') }).to be(true)
      expect(lines.any? { |l| l.include?('coverage_path:') }).to be(true)
      expect(lines.any? { |l| l.include?('report_path:') }).to be(true)
    end

    it 'returns 1 when any path check FAILs' do
      allow(described_class).to receive(:cache_path_check).and_return('FAIL cache_path: /missing')

      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
    end

    it 'rescues StandardError and returns 1 with a clear error message' do
      allow(described_class).to receive(:ruby_version_check).and_raise(StandardError, 'boom')

      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('doctor:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.path_check' do
    it 'returns FAIL line for nil path' do
      expect(described_class.path_check('cache_path:', nil)).to start_with('FAIL')
    end

    it 'returns FAIL line for empty path' do
      expect(described_class.path_check('cache_path:', '')).to start_with('FAIL')
    end

    it 'returns FAIL line for non-existent path' do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, 'does-not-exist')
        expect(described_class.path_check('cache_path:', missing)).to start_with('FAIL')
        expect(described_class.path_check('cache_path:', missing)).to include('does not exist')
      end
    end

    it 'returns FAIL line for non-writable existing path' do
      Dir.mktmpdir do |dir|
        File.chmod(0o555, dir)
        expect(described_class.path_check('cache_path:', dir)).to start_with('FAIL')
      ensure
        File.chmod(0o755, dir)
      end
    end

    it 'returns OK line for writable existing path' do
      Dir.mktmpdir do |dir|
        expect(described_class.path_check('cache_path:', dir)).to start_with('OK')
      end
    end
  end

  describe '.git_check' do
    it 'returns OK when in a git repo' do
      expect(described_class.git_check).to start_with('OK')
    end

    it 'returns WARN outside a git repo' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(described_class.git_check).to start_with('WARN')
        end
      end
    end
  end

  # M8.9: doctor deepening - schema-version compat, remote-cache
  # backend reachability, and AR-schema narrow-attribution config
  # detection. Tests use focused stubs over the live RSpecTracer
  # module since the CLI dispatches against the global module.
  describe '.cache_schema_version_check (M8.9)' do
    it 'returns INFO when no last_run.json exists yet' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive(:cache_path).and_return(dir)
        expect(described_class.cache_schema_version_check).to start_with('INFO schema:')
        expect(described_class.cache_schema_version_check).to include('no cache yet')
      end
    end

    it 'returns OK when stored schema version matches the gem' do
      Dir.mktmpdir do |dir|
        manifest = { 'schema_version' => RSpecTracer::Storage::Schema::CURRENT, 'run_id' => 'abc' }
        File.write(File.join(dir, 'last_run.json'), JSON.dump(manifest))
        allow(RSpecTracer).to receive(:cache_path).and_return(dir)
        expect(described_class.cache_schema_version_check).to start_with('OK   schema:')
      end
    end

    it 'returns WARN with cold-run note when stored schema version differs' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'last_run.json'), JSON.dump('schema_version' => 1, 'run_id' => 'abc'))
        allow(RSpecTracer).to receive(:cache_path).and_return(dir)
        line = described_class.cache_schema_version_check
        expect(line).to start_with('WARN schema:')
        expect(line).to include('cold run')
      end
    end
  end

  describe '.remote_cache_check (M8.9)' do
    it 'returns INFO when no remote_cache backend is configured' do
      allow(RSpecTracer).to receive(:respond_to?).and_call_original
      allow(RSpecTracer).to receive(:respond_to?).with(:remote_cache_backend_entry).and_return(true)
      allow(RSpecTracer).to receive(:remote_cache_backend_entry).and_return(nil)
      expect(described_class.remote_cache_check).to start_with('INFO remote_cache:')
    end

    it 'returns OK with bucket name when :s3 backend is configured' do
      allow(RSpecTracer).to receive(:respond_to?).and_call_original
      allow(RSpecTracer).to receive(:respond_to?).with(:remote_cache_backend_entry).and_return(true)
      allow(RSpecTracer).to receive(:remote_cache_backend_entry).and_return([:s3, { bucket: 'my-bucket' }])
      line = described_class.remote_cache_check
      expect(line).to start_with('OK   remote_cache:')
      expect(line).to include('my-bucket')
    end

    it 'returns WARN when :local_fs path does not exist' do
      allow(RSpecTracer).to receive(:respond_to?).and_call_original
      allow(RSpecTracer).to receive(:respond_to?).with(:remote_cache_backend_entry).and_return(true)
      allow(RSpecTracer).to receive(:remote_cache_backend_entry).and_return([:local_fs, { path: '/nope' }])
      expect(described_class.remote_cache_check).to start_with('WARN remote_cache:')
    end
  end

  describe '.ar_schema_narrow_attribution_check (M8.9)' do
    before do
      allow(RSpecTracer).to receive(:respond_to?).and_call_original
      allow(RSpecTracer).to receive(:respond_to?).with(:track_ar_schema_notifications?).and_return(true)
    end

    it 'returns INFO when track_ar_schema_notifications is disabled' do
      allow(RSpecTracer).to receive(:track_ar_schema_notifications?).and_return(false)
      expect(described_class.ar_schema_narrow_attribution_check).to start_with('INFO AR schema:')
    end

    it 'returns INFO when Rails is not loaded' do
      allow(RSpecTracer).to receive(:track_ar_schema_notifications?).and_return(true)
      hide_const('Rails') if defined?(Rails)
      expect(described_class.ar_schema_narrow_attribution_check).to start_with('INFO AR schema:')
    end
  end

  describe '.simplecov_check / .rails_check' do
    it 'reports SimpleCov as INFO when not loaded' do
      hide_const('::SimpleCov')
      expect(described_class.simplecov_check).to start_with('INFO SimpleCov:')
    end

    it 'reports SimpleCov as OK when loaded' do
      stub_const('::SimpleCov', Module.new)
      expect(described_class.simplecov_check).to start_with('OK   SimpleCov:')
    end

    it 'reports Rails as INFO when not loaded' do
      hide_const('::Rails')
      expect(described_class.rails_check).to start_with('INFO Rails:')
    end

    it 'reports Rails version when loaded' do
      stub_const('::Rails', Module.new)
      stub_const('::Rails::VERSION', Module.new)
      stub_const('::Rails::VERSION::STRING', '8.0.1')
      expect(described_class.rails_check).to include('8.0.1')
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
