# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'set'

require 'rspec_tracer/cli'
require 'rspec_tracer/cli/blast_radius'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::CLI::BlastRadius do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help when no args given' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('Usage: rspec-tracer blast-radius')
    end

    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer blast-radius')
        expect(out.string).to include('git diff --name-only')
        expect(out.string).to include('are not included')
      end
    end

    it 'returns 1 when only flags and no file paths are given' do
      expect(described_class.run(%w[--list], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('blast-radius: no file paths given')
      expect(stderr.string).to include('usage: rspec-tracer blast-radius')
    end

    it 'returns 1 on an unknown option instead of treating it as a file path' do
      expect(described_class.run(%w[--josn lib/foo.rb], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('blast-radius: unknown option "--josn"')
      expect(stderr.string).to include('usage: rspec-tracer blast-radius')
    end

    it 'returns 1 with a clear error when no cache exists' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive_messages(cache_path: dir, root: dir, storage_backend: :json)
        expect(described_class.run(%w[lib/foo.rb], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no cache yet')
      end
    end

    it 'returns 1 when the cache is schema-mismatched' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'last_run.json'),
                   JSON.dump('schema_version' => 9999, 'run_id' => 'stale_run'))
        allow(RSpecTracer).to receive_messages(cache_path: dir, root: dir, storage_backend: :json)
        expect(described_class.run(%w[lib/foo.rb], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('incompatible')
      end
    end

    it 'rescues StandardError and returns 1' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'cache resolve boom')

      expect(described_class.run(%w[lib/foo.rb], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('blast-radius:')
      expect(stderr.string).to include('boom')
    end

    it 'exits 0 silently when a downstream pipe closes early (broken pipe from `| head`)' do
      broken = StringIO.new
      allow(broken).to receive(:puts).and_raise(Errno::EPIPE)
      expect(described_class.run([], stdout: broken, stderr: stderr)).to eq(0)
      expect(stderr.string).to be_empty
    end

    context 'with a populated cache (json backend)' do
      let(:run_id) { 'run_blast' }
      let(:all_examples) do
        {
          'spec/foo_spec.rb[1:1]' => {
            'example_id' => 'spec/foo_spec.rb[1:1]',
            'full_description' => 'Foo does bar',
            'rerun_file_name' => './spec/foo_spec.rb',
            'rerun_line_number' => 12
          },
          'spec/foo_spec.rb[1:2]' => {
            'example_id' => 'spec/foo_spec.rb[1:2]',
            'full_description' => 'Foo does baz',
            'rerun_file_name' => './spec/foo_spec.rb',
            'rerun_line_number' => 20
          },
          'spec/bar_spec.rb[1:1]' => {
            'example_id' => 'spec/bar_spec.rb[1:1]',
            'full_description' => 'Bar works',
            'rerun_file_name' => './spec/bar_spec.rb',
            'rerun_line_number' => 5
          }
        }
      end
      let(:reverse_dependency) do
        {
          '/lib/foo.rb' => Set.new(['spec/foo_spec.rb[1:2]', 'spec/foo_spec.rb[1:1]']),
          '/lib/bar.rb' => Set.new(['spec/bar_spec.rb[1:1]', 'spec/foo_spec.rb[1:2]']),
          '/lib/ghost.rb' => Set.new(['spec/gone_spec.rb[9:9]'])
        }
      end

      before do
        @tmp_dir = Dir.mktmpdir
        @root_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = all_examples
        snapshot.reverse_dependency = reverse_dependency
        snapshot.all_files = {
          '/lib/foo.rb' => { 'file_name' => '/lib/foo.rb' },
          '/lib/bar.rb' => { 'file_name' => '/lib/bar.rb' },
          '/lib/nodeps.rb' => { 'file_name' => '/lib/nodeps.rb' }
        }
        snapshot.boot_set = { 'spec/spec_helper.rb' => 'a' * 64 }
        RSpecTracer::Storage::JsonBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(
          cache_path: @tmp_dir, root: @root_dir, storage_backend: :json
        )
      end

      after do
        FileUtils.rm_rf(@tmp_dir) if @tmp_dir
        FileUtils.rm_rf(@root_dir) if @root_dir
      end

      it 'prints a per-file summary line for a tracked file' do
        expect(described_class.run(%w[lib/foo.rb], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('/lib/foo.rb: 2 examples across 1 spec files')
        expect(stdout.string).not_to include('total:')
      end

      it 'prints per-file lines plus a dedup total for multi-file input' do
        args = %w[lib/foo.rb lib/bar.rb]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('/lib/foo.rb: 2 examples across 1 spec files')
        expect(stdout.string).to include('/lib/bar.rb: 2 examples across 2 spec files')
        expect(stdout.string).to include('total: 3 unique examples across 2 spec files')
      end

      it 'enumerates affected examples sorted by location under --list' do
        args = %w[--list lib/foo.rb]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        first = stdout.string.index('  ./spec/foo_spec.rb:12  Foo does bar')
        second = stdout.string.index('  ./spec/foo_spec.rb:20  Foo does baz')
        expect(first).not_to be_nil
        expect(second).to be > first
      end

      it 'emits a machine-readable JSON document under --json' do
        args = %w[--json lib/foo.rb lib/bar.rb]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        payload = JSON.parse(stdout.string)
        foo = payload['files'].find { |f| f['file_name'] == '/lib/foo.rb' }
        expect(foo).to include(
          'path' => 'lib/foo.rb', 'status' => 'tracked',
          'example_count' => 2, 'spec_file_count' => 1
        )
        expect(foo['examples'].first).to include(
          'example_id' => 'spec/foo_spec.rb[1:1]',
          'location' => './spec/foo_spec.rb:12',
          'description' => 'Foo does bar'
        )
        expect(payload['total']).to eq(
          'example_count' => 3, 'spec_file_count' => 2,
          'whole_suite' => false, 'all_examples_count' => 3
        )
      end

      it 'reports an untracked file as a benign no-op with exit 0' do
        expect(described_class.run(%w[README.md], stdout: stdout, stderr: stderr)).to eq(0)
        # The wording must stick to what the tracer observed (nothing)
        # rather than claiming the file "never loaded": files consumed
        # outside the hooked surface (spec_helper.rb, unhooked reads)
        # load fine yet never land in the cache.
        expect(stdout.string).to include(
          '/README.md: not tracked in cache (no recorded dependents: the tracer never ' \
          'observed it as an input; see the soundness model in ARCHITECTURE.md)'
        )
      end

      it 'reports a tracked file without dependents as 0 examples with exit 0' do
        expect(described_class.run(%w[lib/nodeps.rb], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('/lib/nodeps.rb: 0 examples (no tracked dependents)')
      end

      it 'reports a whole-suite invalidator watch file as re-running everything' do
        expect(described_class.run(%w[Gemfile.lock], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string)
          .to include('/Gemfile.lock: whole-suite invalidator; re-runs all 3 examples')
      end

      it 'reports a boot-set file as re-running everything' do
        expect(described_class.run(%w[spec/spec_helper.rb], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('/spec/spec_helper.rb: boot file; re-runs all 3 examples')
      end

      it 'collapses the total to the whole suite when any input is a whole-suite invalidator' do
        args = %w[lib/foo.rb Gemfile.lock]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('total: all 3 examples (whole-suite invalidator)')
      end

      it 'marks the JSON total as whole_suite when an invalidator is among the inputs' do
        args = %w[--json lib/foo.rb Gemfile.lock]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        payload = JSON.parse(stdout.string)
        gemfile = payload['files'].find { |f| f['file_name'] == '/Gemfile.lock' }
        expect(gemfile['status']).to eq('whole_suite_invalidator')
        expect(payload['total']).to include('whole_suite' => true, 'example_count' => 3)
      end

      it 'resolves an absolute path inside the project root like a relative one' do
        args = [File.join(@root_dir, 'lib/foo.rb')]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('/lib/foo.rb: 2 examples across 1 spec files')
      end

      it 'degrades a dangling example id to <unknown> fields instead of raising' do
        args = %w[--list lib/ghost.rb]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('/lib/ghost.rb: 1 examples across 1 spec files')
        expect(stdout.string).to include('  <unknown>  <unknown>')
      end

      context 'when storage_backend :sqlite degrades to :json mid-command' do
        # Regression for the sqlite3-LoadError fallback path: with
        # `storage_backend :sqlite` and the sqlite3 gem unavailable
        # (every JRuby invocation; MRI without the gem installed),
        # Storage::Backend.build rescues SqliteBackendError, warns
        # through RSpecTracer.logger, and falls back to :json. The
        # logger's default destination is stdout, so before the CLI
        # dispatch layer rebound it to stderr the warning printed
        # AHEAD of the --json document and broke `... --json | jq`.
        before do
          allow(RSpecTracer).to receive(:storage_backend).and_return(:sqlite)
          fallback_error = Class.new(StandardError)
          fake_sqlite = Class.new
          fake_sqlite.const_set(:SqliteBackendError, fallback_error)
          allow(fake_sqlite).to receive(:new).and_raise(
            fallback_error, 'sqlite3 gem not available: cannot load such file -- sqlite3'
          )
          stub_const('RSpecTracer::Storage::SqliteBackend', fake_sqlite)
        end

        it 'emits exactly one parseable JSON document on stdout and the fallback warning on stderr' do
          args = %w[blast-radius --json lib/foo.rb]
          expect(RSpecTracer::CLI.run(args, stdout: stdout, stderr: stderr)).to eq(0)
          # JSON.parse over the WHOLE stdout capture is the contract
          # check: it raises if any diagnostic line precedes or
          # follows the single JSON document.
          payload = JSON.parse(stdout.string)
          expect(payload['files'].first).to include('status' => 'tracked', 'example_count' => 2)
          expect(stderr.string).to include('sqlite backend unavailable')
          expect(stderr.string).to include('falling back to :json')
        end
      end
    end

    context 'with a populated cache (sqlite backend)', :sqlite do
      let(:run_id) { 'run_blast_sqlite' }

      before do
        skip 'sqlite backend unavailable on this Ruby' unless sqlite_available?
        @tmp_dir = Dir.mktmpdir
        @root_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = {
          'spec/foo_spec.rb[1:1]' => {
            'example_id' => 'spec/foo_spec.rb[1:1]',
            'full_description' => 'Foo does bar',
            'rerun_file_name' => './spec/foo_spec.rb',
            'rerun_line_number' => 12
          }
        }
        # SqliteBackend derives reverse_dependency from the dependency
        # table at read time, so the fixture seeds the forward map.
        snapshot.dependency = { 'spec/foo_spec.rb[1:1]' => Set.new(['/lib/foo.rb']) }
        snapshot.reverse_dependency = { '/lib/foo.rb' => Set.new(['spec/foo_spec.rb[1:1]']) }
        RSpecTracer::Storage::SqliteBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(
          cache_path: @tmp_dir, root: @root_dir, storage_backend: :sqlite
        )
      end

      after do
        FileUtils.rm_rf(@tmp_dir) if @tmp_dir
        FileUtils.rm_rf(@root_dir) if @root_dir
      end

      it 'resolves the reverse-dependency radius under storage_backend :sqlite' do
        args = %w[--json lib/foo.rb]
        expect(described_class.run(args, stdout: stdout, stderr: stderr)).to eq(0)
        payload = JSON.parse(stdout.string)
        expect(payload['files'].first).to include('status' => 'tracked', 'example_count' => 1)
        expect(payload['files'].first['examples'].first['description']).to eq('Foo does bar')
      end

      def sqlite_available?
        return false unless RUBY_ENGINE == 'ruby'

        require 'sqlite3'
        require 'rspec_tracer/storage/sqlite_backend'
        true
      rescue LoadError
        false
      end
    end
  end

  describe '.parse_args' do
    it 'separates flags from file paths' do
      parsed = described_class.parse_args(%w[--list a.rb --json b.rb])
      expect(parsed).to eq(list: true, json: true, files: %w[a.rb b.rb], unknown: nil)
    end

    it 'captures the first unknown dash-prefixed arg' do
      parsed = described_class.parse_args(%w[--nope a.rb --also-nope])
      expect(parsed[:unknown]).to eq('--nope')
      expect(parsed[:files]).to eq(%w[a.rb])
    end
  end

  describe '.normalize_file_name' do
    before do
      allow(RSpecTracer).to receive(:root).and_return('/projects/app')
    end

    it 'expands a relative path against the project root with a leading slash' do
      expect(described_class.normalize_file_name('lib/foo.rb')).to eq('/lib/foo.rb')
    end

    it 'swaps the root prefix for a leading slash on an in-root absolute path' do
      expect(described_class.normalize_file_name('/projects/app/lib/foo.rb')).to eq('/lib/foo.rb')
    end

    it 'keeps an absolute path outside the project root as-is' do
      expect(described_class.normalize_file_name('/elsewhere/lib/foo.rb'))
        .to eq('/elsewhere/lib/foo.rb')
    end
  end

  describe '.radius_for' do
    let(:snapshot) do
      instance_double(
        RSpecTracer::Storage::Snapshot,
        all_examples: { 'ex1' => { 'full_description' => 'x' } },
        reverse_dependency: { '/lib/foo.rb' => Set.new(%w[ex1]) },
        all_files: { '/lib/foo.rb' => {}, '/lib/nodeps.rb' => {} },
        boot_set: { 'spec/spec_helper.rb' => 'digest' }
      )
    end

    before do
      allow(RSpecTracer).to receive(:root).and_return('/projects/app')
    end

    it 'classifies a whole-suite invalidator watch file first' do
      expect(described_class.radius_for('Gemfile.lock', snapshot))
        .to include(status: 'whole_suite_invalidator')
    end

    it 'classifies a boot-set member (relative-key convention) as boot_file' do
      expect(described_class.radius_for('spec/spec_helper.rb', snapshot))
        .to include(status: 'boot_file')
    end

    it 'classifies a file with reverse dependents as tracked' do
      radius = described_class.radius_for('lib/foo.rb', snapshot)
      expect(radius[:status]).to eq('tracked')
      expect(radius[:examples].map { |e| e[:example_id] }).to eq(%w[ex1])
    end

    it 'classifies a known file without dependents as no_dependents' do
      expect(described_class.radius_for('lib/nodeps.rb', snapshot))
        .to include(status: 'no_dependents', examples: [])
    end

    it 'classifies an unknown file as untracked' do
      expect(described_class.radius_for('README.md', snapshot))
        .to include(status: 'untracked', examples: [])
    end
  end

  describe '.summary_line' do
    it 'renders each status variant' do
      examples = [{ example_id: 'e', spec_file: 's.rb', location: 's.rb:1', description: 'd' }]
      lines = {
        'tracked' => '/f.rb: 1 examples across 1 spec files',
        'whole_suite_invalidator' => '/f.rb: whole-suite invalidator; re-runs all 1 examples',
        'boot_file' => '/f.rb: boot file; re-runs all 1 examples',
        'untracked' => '/f.rb: not tracked in cache (no recorded dependents: the tracer never ' \
                       'observed it as an input; see the soundness model in ARCHITECTURE.md)',
        'no_dependents' => '/f.rb: 0 examples (no tracked dependents)'
      }
      no_example_statuses = %w[untracked no_dependents]
      lines.each do |status, expected|
        entries = no_example_statuses.include?(status) ? [] : examples
        radius = { path: 'f.rb', file_name: '/f.rb', status: status, examples: entries }
        expect(described_class.summary_line(radius)).to eq(expected)
      end
    end
  end

  describe '.example_entry' do
    # Regression: post-#182 msgpack preserves Symbol keys end-to-end;
    # JSON-deserialized caches yield String keys. CLI helpers must
    # tolerate either shape.
    it 'reads Symbol-keyed meta (msgpack shape)' do
      meta = { rerun_file_name: './spec/a_spec.rb', rerun_line_number: 3, full_description: 'A' }
      expect(described_class.example_entry('id1', meta)).to eq(
        example_id: 'id1', spec_file: './spec/a_spec.rb',
        location: './spec/a_spec.rb:3', description: 'A'
      )
    end

    it 'falls back to file_name/line_number when rerun fields are absent' do
      meta = { 'file_name' => './spec/b_spec.rb', 'line_number' => 7 }
      entry = described_class.example_entry('id2', meta)
      expect(entry[:location]).to eq('./spec/b_spec.rb:7')
      expect(entry[:description]).to eq('<unknown>')
    end

    it 'degrades non-Hash meta to <unknown> fields' do
      expect(described_class.example_entry('id3', nil)).to eq(
        example_id: 'id3', spec_file: '<unknown>',
        location: '<unknown>', description: '<unknown>'
      )
    end
  end

  describe '.json_payload' do
    let(:snapshot) do
      instance_double(RSpecTracer::Storage::Snapshot, all_examples: { 'e1' => {}, 'e2' => {} })
    end

    it 'builds sorted per-file entries plus a dedup total' do
      entry = { example_id: 'e1', spec_file: 's.rb', location: 's.rb:1', description: 'd' }
      radii = [
        { path: 'a.rb', file_name: '/a.rb', status: 'tracked', examples: [entry] },
        { path: 'b.rb', file_name: '/b.rb', status: 'tracked', examples: [entry] }
      ]
      payload = described_class.json_payload(radii, snapshot)
      expect(payload['files'].size).to eq(2)
      expect(payload['files'].first['examples'].first['example_id']).to eq('e1')
      expect(payload['total']).to eq(
        'example_count' => 1, 'spec_file_count' => 1,
        'whole_suite' => false, 'all_examples_count' => 2
      )
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
