# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'

require 'rspec_tracer/rspec/parallel_tests'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/StubbedMock, RSpec/MessageSpies
RSpec.describe RSpecTracer::RSpec::ParallelTests do
  let(:tmp_base)    { Dir.mktmpdir }
  let(:lock_file)   { File.join(tmp_base, 'rspec_tracer.lock') }
  let(:cache_path)  { File.join(tmp_base, 'rspec_tracer_cache', 'parallel_tests_1') }
  let(:report_path) { File.join(tmp_base, 'rspec_tracer_report', 'parallel_tests_1') }
  let(:coverage_path) { File.join(tmp_base, 'rspec_tracer_coverage', 'parallel_tests_1') }
  let(:logger) { spy('Logger') }

  # ENV scoping: snapshot + restore the three env vars this module reads
  # so mutations inside an example cannot leak to other specs (either in
  # the same file or across the suite). `around` guarantees the restore
  # runs even on example failure or raised exceptions.
  around do |example|
    original_env = ENV.to_hash.slice('TEST_ENV_NUMBER', 'PARALLEL_TEST_GROUPS', 'RSPEC_TRACER_VERBOSE')
    %w[TEST_ENV_NUMBER PARALLEL_TEST_GROUPS RSPEC_TRACER_VERBOSE].each { |k| ENV.delete(k) }

    example.run
  ensure
    %w[TEST_ENV_NUMBER PARALLEL_TEST_GROUPS RSPEC_TRACER_VERBOSE].each { |k| ENV.delete(k) }
    original_env.each { |k, v| ENV[k] = v }
  end

  before do
    allow(RSpecTracer).to receive_messages(lock_file: lock_file, cache_path: cache_path,
                                           report_path: report_path, coverage_path: coverage_path,
                                           logger: logger, simplecov?: false,
                                           cache_retention_local_count: nil,
                                           cache_size_warn_per_file_mb: nil,
                                           cache_size_warn_total_mb: nil)
    [cache_path, report_path, coverage_path].each { |p| FileUtils.mkdir_p(File.dirname(p)) }
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  describe '.active?' do
    it 'returns false when neither env var is set' do
      expect(described_class.active?).to be(false)
    end

    it 'returns false when only TEST_ENV_NUMBER is set' do
      ENV['TEST_ENV_NUMBER'] = '1'
      expect(described_class.active?).to be(false)
    end

    it 'returns false when only PARALLEL_TEST_GROUPS is set' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.active?).to be(false)
    end

    it 'returns true when both env vars are set' do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.active?).to be(true)
    end
  end

  describe '.narrator?' do
    it 'is true when parallel_tests is not active (single process is its own narrator)' do
      expect(described_class.narrator?).to be(true)
    end

    it 'is true when TEST_ENV_NUMBER is empty string under parallel_tests' do
      ENV['TEST_ENV_NUMBER'] = ''
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.narrator?).to be(true)
    end

    it 'is true for the first worker (TEST_ENV_NUMBER == 1)' do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.narrator?).to be(true)
    end

    it 'is false for non-first workers' do
      ENV['TEST_ENV_NUMBER'] = '2'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.narrator?).to be(false)
    end
  end

  describe '.verbose?' do
    it 'is false by default' do
      expect(described_class.verbose?).to be(false)
    end

    it 'is true when RSPEC_TRACER_VERBOSE=true' do
      ENV['RSPEC_TRACER_VERBOSE'] = 'true'
      expect(described_class.verbose?).to be(true)
    end
  end

  describe '.log_rollups?' do
    it 'is true when narrator? is true' do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.log_rollups?).to be(true)
    end

    it 'is false for a non-narrator worker without verbose' do
      ENV['TEST_ENV_NUMBER'] = '2'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.log_rollups?).to be(false)
    end

    it 'is true for a non-narrator worker when verbose is on' do
      ENV['TEST_ENV_NUMBER'] = '2'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      ENV['RSPEC_TRACER_VERBOSE'] = 'true'
      expect(described_class.log_rollups?).to be(true)
    end
  end

  describe '.setup!' do
    before do
      ENV['TEST_ENV_NUMBER'] = '3'
      ENV['PARALLEL_TEST_GROUPS'] = '4'
      stub_const('ParallelTests', Module.new)
    end

    it 'returns false when parallel_tests is inactive' do
      ENV.delete('TEST_ENV_NUMBER')
      ENV.delete('PARALLEL_TEST_GROUPS')
      expect(described_class.setup!).to be(false)
    end

    it 'writes the TEST_ENV_NUMBER into the lock file and returns true' do
      expect(described_class.setup!).to be(true)
      expect(File.read(lock_file).to_i).to eq(3)
    end

    it 'keeps the max across concurrent writers (a prior higher value is preserved)' do
      File.write(lock_file, "7\n")

      described_class.setup!

      expect(File.read(lock_file).to_i).to eq(7)
    end

    it 'replaces a lower prior value with the current TEST_ENV_NUMBER' do
      File.write(lock_file, "1\n")

      described_class.setup!

      expect(File.read(lock_file).to_i).to eq(3)
    end

    it 'returns false + logs an error when parallel_tests gem is missing' do
      hide_const('ParallelTests')
      allow(described_class).to receive(:require).with('parallel_tests').and_raise(LoadError, 'no gem')

      expect(described_class.setup!).to be(false)
      expect(logger).to have_received(:error).with(/Failed to load parallel_tests/)
    end
  end

  describe '.last_process?' do
    before { ENV['PARALLEL_TEST_GROUPS'] = '4' }

    it 'is false when parallel_tests is inactive' do
      ENV.delete('PARALLEL_TEST_GROUPS')
      expect(described_class.last_process?).to be(false)
    end

    it 'is false when the parallel_tests gem is not loaded' do
      ENV['TEST_ENV_NUMBER'] = ''
      hide_const('ParallelTests')

      expect(described_class.last_process?).to be(false)
    end

    it 'is true for the first worker (TEST_ENV_NUMBER empty)' do
      ENV['TEST_ENV_NUMBER'] = ''
      require 'parallel_tests'

      expect(described_class.last_process?).to be(true)
    end

    it 'is true for the first worker (TEST_ENV_NUMBER == "1")' do
      ENV['TEST_ENV_NUMBER'] = '1'
      require 'parallel_tests'

      expect(described_class.last_process?).to be(true)
    end

    it 'is false for any non-first worker regardless of PARALLEL_TEST_GROUPS' do
      ENV['TEST_ENV_NUMBER'] = '2'
      require 'parallel_tests'

      expect(described_class.last_process?).to be(false)
    end
  end

  describe '.remove_lock_file!' do
    it 'removes the lock file if present' do
      File.write(lock_file, '1')
      described_class.remove_lock_file!
      expect(File.exist?(lock_file)).to be(false)
    end

    it 'is a no-op when the lock file is already gone' do
      expect { described_class.remove_lock_file! }.not_to raise_error
    end
  end

  describe '.peer_paths_for' do
    it 'returns the existing parallel_tests_* subdirs in the base dir' do
      ENV['PARALLEL_TEST_GROUPS'] = '3'
      base = File.join(tmp_base, 'peers')
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_3'))

      expect(described_class.peer_paths_for(base)).to contain_exactly(
        File.join(base, 'parallel_tests_1'),
        File.join(base, 'parallel_tests_3')
      )
    end

    # Regression: parallel_tests sets PARALLEL_TEST_GROUPS to the
    # user-requested num_processes (CPU count by default), not the
    # actual worker count. When num_processes < spawned-worker count,
    # iterating `1..ENV['PARALLEL_TEST_GROUPS']` would skip the trailing
    # peer dirs and silently lose their snapshots in the merge.
    it 'finds peer dirs whose index exceeds PARALLEL_TEST_GROUPS' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      base = File.join(tmp_base, 'peers')
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_2'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_4'))

      expect(described_class.peer_paths_for(base)).to contain_exactly(
        File.join(base, 'parallel_tests_1'),
        File.join(base, 'parallel_tests_2'),
        File.join(base, 'parallel_tests_4')
      )
    end

    it 'finds peer dirs even when PARALLEL_TEST_GROUPS is unset' do
      base = File.join(tmp_base, 'peers')
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))

      expect(described_class.peer_paths_for(base)).to contain_exactly(
        File.join(base, 'parallel_tests_1')
      )
    end

    it 'returns an empty array when no parallel_tests_* dirs exist' do
      ENV['PARALLEL_TEST_GROUPS'] = '4'
      base = File.join(tmp_base, 'peers')
      FileUtils.mkdir_p(base)

      expect(described_class.peer_paths_for(base)).to eq([])
    end

    it 'rejects file entries with parallel_tests_ prefix' do
      base = File.join(tmp_base, 'peers')
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      File.write(File.join(base, 'parallel_tests_2.json'), 'not a dir')

      expect(described_class.peer_paths_for(base)).to contain_exactly(
        File.join(base, 'parallel_tests_1')
      )
    end
  end

  describe '.finalize!' do
    before do
      ENV['TEST_ENV_NUMBER'] = ''
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      File.write(lock_file, "2\n")
      require 'parallel_tests'
      allow(ParallelTests).to receive(:wait_for_other_processes_to_finish)
      allow(described_class).to receive(:merge_snapshot!)
      allow(described_class).to receive(:merge_coverage!)
      allow(described_class).to receive(:purge_worker_dirs!)
    end

    it 'is a no-op when parallel_tests is inactive' do
      ENV.delete('TEST_ENV_NUMBER')
      ENV.delete('PARALLEL_TEST_GROUPS')
      expect(described_class.finalize!).to be(false)
    end

    it 'is a no-op when this process is not the first worker' do
      ENV['TEST_ENV_NUMBER'] = '2'
      expect(described_class.finalize!).to be(false)
      expect(described_class).not_to have_received(:merge_snapshot!)
    end

    it 'runs the merge + cleanup sequence on the first (elected) worker' do
      result = described_class.finalize!

      expect(result).to be(true)
      expect(described_class).to have_received(:merge_snapshot!)
      expect(described_class).to have_received(:merge_coverage!)
      expect(described_class).to have_received(:purge_worker_dirs!)
      expect(File.exist?(lock_file)).to be(false)
    end

    it 'skips coverage merge when SimpleCov owns coverage emission' do
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)

      described_class.finalize!

      expect(described_class).not_to have_received(:merge_coverage!)
    end

    it 'logs and returns false on StandardError — never propagates exit status' do
      allow(described_class).to receive(:merge_snapshot!).and_raise(StandardError, 'disk full')

      expect(described_class.finalize!).to be(false)
      expect(logger).to have_received(:warn).with(/parallel_tests finalize failed/)
    end
  end

  describe '.merge_snapshot!' do
    let(:schema) { RSpecTracer::Storage::Schema::CURRENT }
    let(:base_dir) { File.dirname(cache_path) }

    before do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_2'))
    end

    it 'is a no-op when no peer directories exist' do
      FileUtils.rm_rf(base_dir)

      expect { described_class.merge_snapshot! }.not_to raise_error
    end

    it 'delegates to JsonBackend#merge_from_peers against the top-level cache dir' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend, merge_from_peers: nil)
      expect(RSpecTracer::Storage::JsonBackend)
        .to receive(:new).with(hash_including(cache_path: base_dir, logger: logger))
        .and_return(backend)

      described_class.merge_snapshot!

      expect(backend).to have_received(:merge_from_peers).with(
        [File.join(base_dir, 'parallel_tests_1'), File.join(base_dir, 'parallel_tests_2')],
        schema_version: schema
      )
    end

    it 'emits a debug log line only when this worker is the narrator' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend, merge_from_peers: nil)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)

      described_class.merge_snapshot!

      expect(logger).to have_received(:debug).with(/merged parallel tests reports/)
    end

    it 'suppresses the debug line for non-narrator workers unless verbose' do
      ENV['TEST_ENV_NUMBER'] = '2'
      backend = instance_double(RSpecTracer::Storage::JsonBackend, merge_from_peers: nil)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)

      described_class.merge_snapshot!

      expect(logger).not_to have_received(:debug)
    end
  end

  describe '.merge_coverage!' do
    let(:base_dir) { File.dirname(coverage_path) }

    before do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_2'))
    end

    it 'is a no-op when no peer coverage directories exist' do
      FileUtils.rm_rf(base_dir)

      expect { described_class.merge_coverage! }.not_to raise_error
    end

    it 'merges via Reporters::CoverageJsonReporter.merge_parallel + emits a debug rollup line' do
      allow(RSpecTracer::Reporters::CoverageJsonReporter).to receive(:merge_parallel)
      allow(described_class).to receive(:log_rollups?).and_return(true)
      logger = spy('Logger')
      allow(RSpecTracer).to receive(:logger).and_return(logger)

      described_class.merge_coverage!

      expect(RSpecTracer::Reporters::CoverageJsonReporter).to have_received(:merge_parallel).with(
        peer_paths: [File.join(base_dir, 'parallel_tests_1'), File.join(base_dir, 'parallel_tests_2')],
        output_path: File.join(base_dir, 'coverage.json'),
        logger: logger
      )
      expect(logger).to have_received(:debug).with(/merged parallel tests coverage/)
    end
  end

  describe '.purge_worker_dirs!' do
    it 'removes the parallel_tests_N subdirs under each tracked base dir' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      [cache_path, report_path, coverage_path].each do |path|
        FileUtils.mkdir_p(File.join(File.dirname(path), 'parallel_tests_1'))
        FileUtils.mkdir_p(File.join(File.dirname(path), 'parallel_tests_2'))
      end

      described_class.purge_worker_dirs!

      [cache_path, report_path, coverage_path].each do |path|
        (1..2).each do |n|
          expect(File.directory?(File.join(File.dirname(path), "parallel_tests_#{n}"))).to be(false)
        end
      end
    end

    # Regression for spec/integration/parallel_tests_spec.rb:88 flake
    # on ruby-parallel CI cells: parallel_tests sets
    # PARALLEL_TEST_GROUPS = num_processes (the user-requested process
    # count), not the actual worker count. When the spawned worker
    # count exceeds num_processes (e.g. via spec-count partitioning
    # interactions or shared-runner CPU detection drift), iterating
    # `1..ENV['PARALLEL_TEST_GROUPS']` left worker dirs above that
    # bound behind. Globbing the actual filesystem state is robust.
    it 'sweeps worker dirs whose index exceeds PARALLEL_TEST_GROUPS' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      base = File.dirname(cache_path)
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_4'))

      described_class.purge_worker_dirs!

      expect(Dir.glob(File.join(base, 'parallel_tests_*'))).to be_empty
    end

    it 'sweeps worker dirs even when PARALLEL_TEST_GROUPS is unset' do
      base = File.dirname(cache_path)
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_2'))

      described_class.purge_worker_dirs!

      expect(Dir.glob(File.join(base, 'parallel_tests_*'))).to be_empty
    end

    it 'is a no-op when no worker dirs exist' do
      ENV['PARALLEL_TEST_GROUPS'] = '4'
      expect { described_class.purge_worker_dirs! }.not_to raise_error
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/StubbedMock, RSpec/MessageSpies
