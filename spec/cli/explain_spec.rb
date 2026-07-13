# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'set'

require 'rspec_tracer/cli/explain'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::CLI::Explain do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help when no args given' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('Usage: rspec-tracer explain')
    end

    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer explain')
      end
    end

    it 'exits 0 silently when a downstream pipe closes early (broken pipe from `| head`)' do
      broken = StringIO.new
      allow(broken).to receive(:puts).and_raise(Errno::EPIPE)
      expect(described_class.run([], stdout: broken, stderr: stderr)).to eq(0)
      expect(stderr.string).to be_empty
    end

    it 'returns 1 with a clear error when no cache exists' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive_messages(cache_path: dir, storage_backend: :json)
        expect(described_class.run(%w[anything], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no cache yet')
      end
    end

    it 'returns 1 when the cache is schema-mismatched' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'last_run.json'),
                   JSON.dump('schema_version' => 9999, 'run_id' => 'stale_run'))
        allow(RSpecTracer).to receive_messages(cache_path: dir, storage_backend: :json)
        expect(described_class.run(%w[any], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('incompatible')
      end
    end

    context 'with a populated cache (json backend)' do
      let(:run_id) { 'run_xyz' }
      let(:example_meta) do
        {
          'example_id' => 'a/spec.rb[1:1]',
          'full_description' => 'Foo does bar',
          'rerun_file_name' => './spec/foo_spec.rb',
          'rerun_line_number' => 12,
          'execution_result' => { 'status' => 'passed' },
          'run_reason' => 'changed'
        }
      end

      before do
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = { 'a/spec.rb[1:1]' => example_meta }
        snapshot.dependency = { 'a/spec.rb[1:1]' => Set.new(['./spec/foo_spec.rb', './lib/foo.rb']) }
        RSpecTracer::Storage::JsonBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :json)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'returns 1 when no example matches the query' do
        expect(described_class.run(%w[totally_bogus], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no example matching')
      end

      it 'matches by exact example_id and prints the full explanation' do
        expect(described_class.run(['a/spec.rb[1:1]'], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
        expect(stdout.string).to include('passed')
        expect(stdout.string).to include('changed')
        expect(stdout.string).to include('./lib/foo.rb')
        expect(stdout.string).not_to include('carried forward')
      end

      it 'falls back to substring match on full_description' do
        expect(described_class.run(%w[Foo], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
      end
    end

    it 'prints help when --not-run is given without a positional' do
      expect(described_class.run(%w[--not-run], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('Usage: rspec-tracer explain')
    end

    it 'documents --not-run in the help text' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('--not-run')
    end

    context 'with --not-run against a populated cache (json backend)' do
      def skipped_id
        'a/spec.rb[1:1]'
      end

      def ran_id
        'a/spec.rb[1:2]'
      end

      def failed_id
        'a/spec.rb[1:3]'
      end

      def absent_id
        'a/spec.rb[1:4]'
      end

      def meta_for(id, desc)
        {
          'example_id' => id,
          'full_description' => desc,
          'rerun_file_name' => './spec/foo_spec.rb',
          'rerun_line_number' => 12,
          'execution_result' => { 'status' => 'passed' },
          'run_reason' => 'stale prior-run reason'
        }
      end

      before do
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: 'run_not_run'
        )
        snapshot.all_examples = {
          skipped_id => meta_for(skipped_id, 'Foo skips cleanly'),
          ran_id => meta_for(ran_id, 'Foo ran again'),
          failed_id => meta_for(failed_id, 'Foo failed before'),
          absent_id => meta_for(absent_id, 'Foo sat out the last run')
        }
        snapshot.skipped_examples = Set.new([skipped_id])
        snapshot.filtered_examples = { ran_id => 'Files changed', failed_id => 'Failed previously' }
        snapshot.failed_examples = Set.new([failed_id])
        snapshot.dependency = {
          skipped_id => Set.new(['./spec/foo_spec.rb', './lib/foo.rb'])
        }
        RSpecTracer::Storage::JsonBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :json)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'explains a skipped example with the itemized skip-reason derivation' do
        expect(described_class.run(['--not-run', skipped_id], stdout: stdout, stderr: stderr)).to eq(0)
        out = stdout.string
        expect(out).to include('last run:     skipped (cache hit)')
        expect(out).to include('skip reason:  no run trigger fired last run:')
        expect(out).to include('whole-suite invalidators (Gemfile.lock, .ruby-version, .rspec-tracer, gem version)')
        expect(out).to include('boot set: no boot file changed')
        expect(out).to include('prior status: not failed / flaky / pending / interrupted')
        expect(out).to include('dependency files: 2 tracked, none changed')
        expect(out).to include('environment snapshot: unchanged for this example')
        expect(out).to include('last status:  passed (most recent snapshot; this cache keeps only the last run)')
        expect(out).to include(
          'next run:     runs only if a dependency, whole-suite invalidator, boot file, or tracked env var changes'
        )
        expect(out).to include('dependencies: 2 files tracked')
        expect(out).to include('./lib/foo.rb')
      end

      it 'attributes an absent filter decision to the run, not the storage backend, on json' do
        # A cold run persists EMPTY filtered_examples/skipped_examples
        # by design (the engine computes no filter decisions without a
        # previous snapshot), and an id that was not part of the last
        # run has no entry either; neither is a backend limitation
        # on the json backend, which persists the field.
        expect(described_class.run(['--not-run', absent_id], stdout: stdout, stderr: stderr)).to eq(0)
        out = stdout.string
        expect(out).to include(
          'last run:     no filter decision recorded (cold run, or this example was not part of it)'
        )
        expect(out).not_to include('not recorded by this storage backend')
      end

      it 'omits the stale carry-forward run reason from the --not-run view' do
        expect(described_class.run(['--not-run', skipped_id], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).not_to include('stale prior-run reason')
        expect(stdout.string).not_to include('run reason:')
      end

      it 'tells the truth when the example actually ran, with a run-side hint' do
        expect(described_class.run(['--not-run', ran_id], stdout: stdout, stderr: stderr)).to eq(0)
        out = stdout.string
        expect(out).to include('last run:     ran (Files changed)')
        expect(out).to include("it was not skipped; run 'rspec-tracer explain #{ran_id}' for the run-side view")
      end

      it 'predicts the unconditional re-run for a previously failed example' do
        expect(described_class.run(['--not-run', failed_id], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('next run:     will re-run regardless (failed last run)')
      end

      it 'returns 1 on --not-run with no matching example' do
        expect(described_class.run(%w[--not-run totally_bogus], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no example matching')
      end

      it 'flags the carry-forward run reason in the plain view for a skipped example' do
        # The persisted run_reason on a skipped example is seeded from
        # an earlier snapshot; echoing it bare would misreport why the
        # example did not run last time.
        expect(described_class.run([skipped_id], stdout: stdout, stderr: stderr)).to eq(0)
        out = stdout.string
        expect(out).to include(
          'run reason:   stale prior-run reason (carried forward from an earlier run; ' \
          'this example was SKIPPED last run; use --not-run for the skip-side view)'
        )
        expect(out).not_to include('last run:')
      end

      it 'prints the run reason bare in the plain view for an example that actually ran' do
        expect(described_class.run([ran_id], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('run reason:   stale prior-run reason')
        expect(stdout.string).not_to include('carried forward')
        expect(stdout.string).not_to include('last run:')
      end
    end

    context 'with --not-run against a sqlite cache that does not persist filtered_examples', :sqlite do
      let(:run_id) { 'run_not_run_sqlite' }
      let(:ran_id) { 'a/spec.rb[1:2]' }

      before do
        skip 'sqlite backend unavailable on this Ruby' unless sqlite_available?
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = {
          ran_id => {
            'example_id' => ran_id,
            'full_description' => 'Foo ran again',
            'rerun_file_name' => './spec/foo_spec.rb',
            'rerun_line_number' => 12,
            'execution_result' => { 'status' => 'passed' }
          }
        }
        snapshot.filtered_examples = { ran_id => 'Files changed' }
        RSpecTracer::Storage::SqliteBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :sqlite)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'degrades to the not-recorded fallback without failing' do
        expect(described_class.run(['--not-run', ran_id], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('last run:     <not recorded by this storage backend>')
        expect(stdout.string).to include('next run:')
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

    context 'with a populated cache (sqlite backend)', :sqlite do
      let(:run_id) { 'run_sqlite_xyz' }

      before do
        skip 'sqlite backend unavailable on this Ruby' unless sqlite_available?
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = {
          'a/spec.rb[1:1]' => {
            'example_id' => 'a/spec.rb[1:1]',
            'full_description' => 'Foo does bar',
            'rerun_file_name' => './spec/foo_spec.rb',
            'rerun_line_number' => 12,
            'execution_result' => { 'status' => 'passed' },
            'run_reason' => 'changed'
          }
        }
        snapshot.dependency = { 'a/spec.rb[1:1]' => Set.new(['./spec/foo_spec.rb', './lib/foo.rb']) }
        RSpecTracer::Storage::SqliteBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :sqlite)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      # Regression for #183: the CLI must load the snapshot through
      # the backend protocol (sqlite's LazySnapshot) and resolve
      # all_examples + dependency from there, not the JsonBackend
      # `last_run.json` + per-field-file layout.
      it 'resolves example metadata + dependency under storage_backend :sqlite' do
        expect(described_class.run(['a/spec.rb[1:1]'], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
        expect(stdout.string).to include('./lib/foo.rb')
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

    it 'rescues StandardError and returns 1' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'cache resolve boom')

      expect(described_class.run(%w[any], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('explain:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.find_example' do
    let(:examples) do
      {
        'a' => { 'full_description' => 'Foo does bar' },
        'b' => { 'full_description' => 'Baz works correctly' }
      }
    end

    it 'returns the meta on exact id match' do
      expect(described_class.find_example(examples, 'a')).to eq(examples['a'])
    end

    it 'returns the meta on substring match against description' do
      expect(described_class.find_example(examples, 'Baz')).to eq(examples['b'])
    end

    it 'returns nil on no match' do
      expect(described_class.find_example(examples, 'totally_unrelated')).to be_nil
    end
  end

  describe '--not-run helpers' do
    let(:snapshot) do
      RSpecTracer::Storage::Snapshot.empty(schema_version: 1, run_id: 'helper_run')
    end

    describe '.last_run_line' do
      it 'reports skipped (cache hit) for a skipped id' do
        snapshot.skipped_examples = Set.new(%w[ex_1])
        expect(described_class.last_run_line('ex_1', snapshot, filter_persisted: true))
          .to eq('last run:     skipped (cache hit)')
      end

      it 'reports ran with the recorded reason for a filtered id' do
        snapshot.filtered_examples = { 'ex_1' => 'No cache' }
        expect(described_class.last_run_line('ex_1', snapshot, filter_persisted: true))
          .to eq('last run:     ran (No cache)')
      end

      it 'attributes an empty decision set to the run when the backend persists decisions' do
        expect(described_class.last_run_line('ex_1', snapshot, filter_persisted: true))
          .to eq('last run:     no filter decision recorded (cold run, or this example was not part of it)')
      end

      it 'blames the storage backend only when it does not persist filter decisions' do
        expect(described_class.last_run_line('ex_1', snapshot, filter_persisted: false))
          .to eq('last run:     <not recorded by this storage backend>')
      end

      it 'tolerates nil skipped_examples and filtered_examples fields' do
        snapshot.skipped_examples = nil
        snapshot.filtered_examples = nil
        expect(described_class.last_run_line('ex_1', snapshot, filter_persisted: false)).to include('<not recorded')
      end
    end

    describe '.skip_reason_lines' do
      it 'itemizes every declined trigger with the tracked dependency count' do
        snapshot.dependency = { 'ex_1' => Set.new(%w[./lib/a.rb ./lib/b.rb ./lib/c.rb]) }
        lines = described_class.skip_reason_lines('ex_1', snapshot)
        expect(lines.first).to eq('skip reason:  no run trigger fired last run:')
        expect(lines).to include('  - dependency files: 3 tracked, none changed')
        expect(lines.any? { |l| l.include?('whole-suite invalidators') }).to be(true)
        # The engine ORs the boot-set check into whole-suite
        # invalidation, so a skip also implies no boot file changed.
        expect(lines).to include('  - boot set: no boot file changed')
        expect(lines.any? { |l| l.include?('prior status') }).to be(true)
        expect(lines.any? { |l| l.include?('environment snapshot') }).to be(true)
      end

      it 'reports zero tracked dependency files when the id has no entry' do
        snapshot.dependency = nil
        lines = described_class.skip_reason_lines('ex_1', snapshot)
        expect(lines).to include('  - dependency files: 0 tracked, none changed')
      end
    end

    describe '.always_rerun_reason' do
      it 'returns each status label for membership in its id set' do
        %w[interrupted flaky failed pending].each do |status|
          fresh = RSpecTracer::Storage::Snapshot.empty(schema_version: 1, run_id: 'r')
          fresh["#{status}_examples"] = Set.new(%w[ex_1])
          expect(described_class.always_rerun_reason('ex_1', fresh)).to eq(status)
        end
      end

      it 'resolves ties in filter precedence order (interrupted first)' do
        snapshot.interrupted_examples = Set.new(%w[ex_1])
        snapshot.failed_examples = Set.new(%w[ex_1])
        expect(described_class.always_rerun_reason('ex_1', snapshot)).to eq('interrupted')
      end

      it 'returns nil when the id carries no always-re-run status' do
        expect(described_class.always_rerun_reason('ex_1', snapshot)).to be_nil
      end
    end

    describe '.next_run_line' do
      it 'predicts an unconditional re-run for a status-carrying id' do
        snapshot.flaky_examples = Set.new(%w[ex_1])
        expect(described_class.next_run_line('ex_1', snapshot))
          .to eq('will re-run regardless (flaky last run)')
      end

      it 'predicts a conditional run otherwise, enumerating the boot-file trigger too' do
        expect(described_class.next_run_line('ex_1', snapshot))
          .to eq('runs only if a dependency, whole-suite invalidator, boot file, or tracked env var changes')
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
