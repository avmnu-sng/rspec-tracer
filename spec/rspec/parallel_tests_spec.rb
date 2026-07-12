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

    it 'drops a .rspec_tracer_boot breadcrumb in this worker\'s cache dir' do
      described_class.setup!

      boot_path = File.join(cache_path, described_class::BOOT_MARKER_FILENAME)
      expect(File).to exist(boot_path)
      payload = JSON.parse(File.read(boot_path))
      expect(payload).to include('pid' => Process.pid, 'test_env_number' => '3')
      expect(payload['started_at']).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it 'logs and continues when the boot-marker write raises (graceful degradation)' do
      allow(File).to receive(:write).and_raise(StandardError, 'disk full')

      expect(described_class.setup!).to be(true)
      expect(logger).to have_received(:warn).with(/failed to write boot marker/)
    end
  end

  describe '.touch_done!' do
    it 'writes the .rspec_tracer_done marker into the worker cache dir' do
      described_class.touch_done!

      done_path = File.join(cache_path, described_class::DONE_MARKER_FILENAME)
      expect(File).to exist(done_path)
      expect(File.read(done_path)).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it 'creates the cache dir when it does not yet exist (no-examples / early-exit path)' do
      FileUtils.rm_rf(File.dirname(cache_path))

      described_class.touch_done!

      expect(File.directory?(cache_path)).to be(true)
    end

    it 'logs and returns nil on StandardError — never propagates exit status' do
      allow(File).to receive(:write).and_raise(StandardError, 'disk full')

      expect { described_class.touch_done! }.not_to raise_error
      expect(logger).to have_received(:warn).with(/failed to write done marker/)
    end
  end

  describe '.wait_for_peer_done_markers!' do
    let(:base_dir) { File.dirname(cache_path) }

    def write_marker(worker, name)
      dir = File.join(base_dir, "parallel_tests_#{worker}")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, name), 'x')
    end

    it 'returns immediately when every booted peer has a .done marker' do
      write_marker(1, described_class::BOOT_MARKER_FILENAME)
      write_marker(1, described_class::DONE_MARKER_FILENAME)
      write_marker(2, described_class::BOOT_MARKER_FILENAME)
      write_marker(2, described_class::DONE_MARKER_FILENAME)

      expect { described_class.wait_for_peer_done_markers! }.not_to raise_error
      expect(logger).not_to have_received(:warn)
    end

    it 'returns immediately when no peer ever wrote .boot (single-process / inactive)' do
      expect { described_class.wait_for_peer_done_markers! }.not_to raise_error
    end

    it 'logs the missing-peer warning and proceeds once the deadline elapses' do
      write_marker(2, described_class::BOOT_MARKER_FILENAME)
      stub_const("#{described_class}::PEER_DONE_DEADLINE_SECONDS", 0)
      allow(described_class).to receive(:sleep)

      expect { described_class.wait_for_peer_done_markers! }.not_to raise_error
      expect(logger).to have_received(:warn)
        .with(/peers booted without finishing within 0s.*parallel_tests_2/)
    end

    it 'returns once a previously-missing .done marker appears mid-poll' do
      write_marker(2, described_class::BOOT_MARKER_FILENAME)
      polls = 0
      allow(described_class).to receive(:sleep) do
        polls += 1
        write_marker(2, described_class::DONE_MARKER_FILENAME) if polls == 1
      end

      expect { described_class.wait_for_peer_done_markers! }.not_to raise_error
      expect(polls).to eq(1)
      expect(logger).not_to have_received(:warn)
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
      allow(described_class).to receive(:wait_for_peer_done_markers!)
      allow(described_class).to receive(:merge_snapshot!)
      allow(described_class).to receive(:merge_coverage!)
      allow(described_class).to receive(:emit_merged_reporters!)
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

    # Every worker — elected or not — drops a .done marker as the
    # first thing in finalize. The elected worker's
    # wait_for_peer_done_markers! reads exactly these markers; if
    # touch_done! were gated on last_process?, non-elected workers
    # would never signal completion and the elected would always
    # time out.
    it 'writes the .done marker even on non-elected workers' do
      ENV['TEST_ENV_NUMBER'] = '2'
      described_class.finalize!

      # `RSpecTracer.cache_path` is stubbed to a fixed path in this
      # spec (parallel_tests_1 in the helper); the non-elected
      # branch still routes through that stub, so .done lands there.
      expect(File).to exist(File.join(cache_path, described_class::DONE_MARKER_FILENAME))
    end

    it 'runs the merge + cleanup sequence on the first (elected) worker' do
      result = described_class.finalize!

      expect(result).to be(true)
      expect(described_class).to have_received(:wait_for_peer_done_markers!)
      expect(described_class).to have_received(:merge_snapshot!)
      expect(described_class).to have_received(:merge_coverage!)
      expect(described_class).to have_received(:emit_merged_reporters!)
      expect(described_class).to have_received(:purge_worker_dirs!)
      expect(File.exist?(lock_file)).to be(false)
    end

    it 'skips coverage merge when SimpleCov owns coverage emission' do
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)

      described_class.finalize!

      expect(described_class).not_to have_received(:merge_coverage!)
    end

    # The peer-done barrier MUST run after the pid wait + before the
    # merge. The pid wait alone is the weak signal that motivated
    # this barrier; running merge before peer-done verification would
    # let a slow peer's snapshot land mid-merge and miss the union.
    it 'runs wait_for_peer_done_markers! between pid-wait and merge_snapshot!' do
      ordering = []
      allow(ParallelTests).to receive(:wait_for_other_processes_to_finish) { ordering << :pid_wait }
      allow(described_class).to receive(:wait_for_peer_done_markers!) { ordering << :peer_wait }
      allow(described_class).to receive(:merge_snapshot!) { ordering << :merge }

      described_class.finalize!

      expect(ordering).to eq(%i[pid_wait peer_wait merge])
    end

    # emit_merged_reporters! must run BEFORE purge_worker_dirs!
    # so the reporter Registry consumes the merged top-level snapshot
    # AND writes its terminal/JSON/HTML output before the per-worker
    # parallel_tests_N dirs are removed.
    it 'emits merged reporters before purging the per-worker dirs' do
      ordering = []
      allow(described_class).to receive(:emit_merged_reporters!) { ordering << :emit }
      allow(described_class).to receive(:purge_worker_dirs!) { ordering << :purge }

      described_class.finalize!

      expect(ordering).to eq(%i[emit purge])
    end

    it 'logs and returns false on StandardError — never propagates exit status' do
      allow(described_class).to receive(:merge_snapshot!).and_raise(StandardError, 'disk full')

      expect(described_class.finalize!).to be(false)
      expect(logger).to have_received(:warn).with(/parallel_tests finalize failed/)
    end

    it 'skips ParallelTests.wait_for_other_processes_to_finish when the gem constant is not defined' do
      # last_process? itself short-circuits on `defined?(::ParallelTests)`
      # before line 148 is reached, so stub it to true to isolate the
      # line 148 defensive guard branch.
      allow(described_class).to receive(:last_process?).and_return(true)
      hide_const('ParallelTests')

      expect(described_class.finalize!).to be(true)
      # Both barriers (gem-internal pid wait + our peer-done filesystem
      # check) are independent; the .done-marker barrier still runs.
      expect(described_class).to have_received(:wait_for_peer_done_markers!)
    end
  end

  describe '.emit_merged_reporters!' do
    let(:base_dir) { File.dirname(cache_path) }
    let(:top_report_dir) { File.dirname(report_path) }
    let(:merged_snapshot) { instance_double(RSpecTracer::Storage::Snapshot) }

    before do
      allow(RSpecTracer).to receive_messages(storage_backend: :json,
                                             storage_backend_opts: {})
      allow(RSpecTracer).to receive(:rails?).and_return(false)
    end

    it 'is a no-op for non-:json storage backends (SqliteBackend)' do
      allow(RSpecTracer).to receive(:storage_backend).and_return(:sqlite)
      expect(RSpecTracer::Reporters::Registry).not_to receive(:emit_all)

      described_class.emit_merged_reporters!
    end

    it 'returns early when load_graph yields no merged snapshot' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend, load_graph: nil)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)
      expect(RSpecTracer::Reporters::Registry).not_to receive(:emit_all)

      described_class.emit_merged_reporters!
    end

    it 'emits the registry against the merged snapshot at the top-level report dir' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend, load_graph: merged_snapshot)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)
      expect(RSpecTracer::Reporters::Registry).to receive(:emit_all).with(
        hash_including(
          configuration: RSpecTracer,
          snapshot: merged_snapshot,
          report_dir: top_report_dir,
          run_metadata: hash_including(parallel_tests: true, cache_path: base_dir)
        )
      )

      described_class.emit_merged_reporters!
    end

    it 'logs and continues on StandardError (purge / lock cleanup not blocked)' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend)
      allow(backend).to receive(:load_graph).and_raise(StandardError, 'boom')
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)

      expect { described_class.emit_merged_reporters! }.not_to raise_error
      expect(logger).to have_received(:warn).with(/merged reporter emission failed/)
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

    it 'is a no-op when storage_backend is not :json (sqlite has no JSON merge surface)' do
      allow(RSpecTracer).to receive(:storage_backend).and_return(:sqlite)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new)

      described_class.merge_snapshot!

      expect(RSpecTracer::Storage::JsonBackend).not_to have_received(:new)
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

    it 'suppresses the debug rollup line when log_rollups? is false (non-narrator quiet path)' do
      allow(RSpecTracer::Reporters::CoverageJsonReporter).to receive(:merge_parallel)
      allow(described_class).to receive(:log_rollups?).and_return(false)
      logger = spy('Logger')
      allow(RSpecTracer).to receive(:logger).and_return(logger)

      described_class.merge_coverage!

      expect(RSpecTracer::Reporters::CoverageJsonReporter).to have_received(:merge_parallel)
      expect(logger).not_to have_received(:debug)
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
