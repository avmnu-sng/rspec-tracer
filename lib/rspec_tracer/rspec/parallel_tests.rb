# frozen_string_literal: true

require 'fileutils'
require 'json'

module RSpecTracer
  # Internal RSpec — see {RSpecTracer} for the user-facing surface.
  # @api private
  module RSpec
    # parallel_tests orchestration for the v2 engine.
    #
    # 1.x scattered the parallel-worker glue across `lib/rspec_tracer.rb`
    # (`parallel_tests_setup`, `track_parallel_tests_test_env_number`,
    # `run_parallel_tests_exit_tasks`, `merge_parallel_tests_reports`,
    # `parallel_tests_last_process?`, etc). 2.0 collapses them here and
    # rewires the snapshot merge onto `Storage::JsonBackend#merge_from_peers`
    # so any storage backend (including SQLite) gets the merge for free.
    #
    # Responsibilities:
    #   - Detect `TEST_ENV_NUMBER` + `PARALLEL_TEST_GROUPS` env vars.
    #   - Maintain the shared `rspec_tracer.lock` file that records the
    #     highest TEST_ENV_NUMBER seen (last-process detection).
    #   - Decide the narrator: first process by env convention. Log
    #     rollup lines only on the narrator unless
    #     `RSPEC_TRACER_VERBOSE=true`.
    #   - On the last process, merge per-worker snapshots +
    #     coverage.json, purge `parallel_tests_N/` directories.
    #
    # Graceful degradation: every merge / cleanup step rescues
    # StandardError and logs - a partial or corrupt peer cache must
    # never propagate a non-zero exit into the user's test run.
    module ParallelTests
      # Internal constant.
      # @api private
      LOCK_ENCODING = 'UTF-8'

      # Per-worker boot/done breadcrumbs written to each worker's
      # `parallel_tests_N/` cache dir. The elected worker uses these
      # at finalize time to verify every booted peer has reached the
      # end of its at_exit before merge + purge:
      #
      #   .boot — written at setup! time (very early, before any
      #           cache write). Source-of-truth for "this worker
      #           ever booted past RSpecTracer.start".
      #   .done — written at finalize entry, AFTER per-worker
      #           run_finalize + emit_coverage_json. Must be the
      #           last write our code does into parallel_tests_N/
      #           on the worker side - the elected reads its
      #           presence as "this peer is fully flushed".
      #
      # Verification path: see `wait_for_peer_done_markers!`. Without
      # this the elected trusted only `wait_for_other_processes_to_finish`'s
      # pid-file barrier, which observed evidence on GHA Linux x86_64
      # showed could return before a sibling had flushed - leaving a
      # straggler `parallel_tests_N/` after purge (failing
      # spec/integration/parallel_tests_spec.rb:88 intermittently).
      BOOT_MARKER_FILENAME = '.rspec_tracer_boot'
      # Internal constant.
      # @api private
      DONE_MARKER_FILENAME = '.rspec_tracer_done'

      # Bound on the elected worker's wait for missing .done markers.
      # 5s comfortably exceeds the at_exit tail of any well-behaved
      # peer; on timeout we log + proceed (graceful degradation: a
      # truly-crashed peer must not pin the elected forever).
      PEER_DONE_DEADLINE_SECONDS = 5

      # Internal helper for the tracer pipeline.
      # @api private
      def self.active?
        return false if ::ENV.fetch('TEST_ENV_NUMBER', nil).nil?
        return false if ::ENV.fetch('PARALLEL_TEST_GROUPS', nil).nil?

        true
      end

      # Narrator = first process. TEST_ENV_NUMBER is either '' or '1'
      # for the first worker under parallel_tests; otherwise '2', '3',
      # etc. When the gem is not running under parallel_tests, the
      # single process is its own narrator.
      def self.narrator?
        return true unless active?

        value = ::ENV.fetch('TEST_ENV_NUMBER', '').to_s
        value.empty? || value == '1'
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.verbose?
        ::ENV.fetch('RSPEC_TRACER_VERBOSE', nil) == 'true'
      end

      # True iff this worker should emit rollup log lines. Per-example
      # RSpec output (dots, failures, durations) is unaffected - that's
      # RSpec's own Reporter, not this module.
      def self.log_rollups?
        verbose? || narrator?
      end

      # Called from RSpecTracer.start when parallel_tests is active.
      # Writes this worker's TEST_ENV_NUMBER into the shared lock file
      # under an exclusive lock so the max-seen value ends up correct
      # regardless of worker boot order, then drops the .boot
      # breadcrumb so the elected worker can enumerate "every peer
      # that booted" at finalize time.
      def self.setup!
        return false unless active?

        require 'parallel_tests' unless defined?(::ParallelTests)
        track_test_env_number!
        touch_boot!
        true
      rescue LoadError => e
        RSpecTracer.logger.error("Failed to load parallel_tests gem (#{e.class}: #{e.message})")
        false
      end

      # Write `parallel_tests_N/.rspec_tracer_boot` with this worker's
      # pid + TEST_ENV_NUMBER + timestamp. Source-of-truth for "this
      # worker booted past RSpecTracer.start", consumed by the elected
      # worker's finalize-time peer enumeration. Idempotent: a re-run
      # of setup! overwrites with current values.
      def self.touch_boot!
        ::FileUtils.mkdir_p(RSpecTracer.cache_path)
        ::File.write(
          ::File.join(RSpecTracer.cache_path, BOOT_MARKER_FILENAME),
          ::JSON.generate(
            pid: ::Process.pid,
            test_env_number: ::ENV.fetch('TEST_ENV_NUMBER', ''),
            started_at: ::Time.now.utc.iso8601
          )
        )
      rescue StandardError => e
        RSpecTracer.logger.warn(
          "RSpec tracer: failed to write boot marker (#{e.class}: #{e.message})"
        )
      end

      # Called from at_exit after the per-worker snapshot has been
      # persisted. Every worker drops its `.done` marker as the very
      # first step here so the elected worker's verification loop can
      # observe it; non-elected workers then return. The elected
      # worker waits for every booted peer's `.done` to appear,
      # orchestrates the snapshot + coverage merge, emits the merged
      # reporters, and purges per-worker dirs.
      #
      # `touch_done!` MUST stay the last write our code performs into
      # `parallel_tests_N/` — anything written later would land after
      # the elected has decided it's safe to purge, leaving stragglers.
      def self.finalize!
        return false unless active?

        touch_done!

        return false unless last_process?

        ::ParallelTests.wait_for_other_processes_to_finish if defined?(::ParallelTests)

        # Belt-and-suspenders barrier: pid-file said everyone's done,
        # but observed CI evidence (GHA Linux x86_64, Ruby 3.4 cells)
        # caught a sibling's `parallel_tests_N/` reappearing post-purge
        # — i.e., the pid signal returned while a peer hadn't fully
        # flushed yet. Cross-check via the .boot/.done filesystem
        # markers before declaring the peer set stable.
        wait_for_peer_done_markers!

        merge_snapshot!
        merge_coverage! unless RSpecTracer.simplecov?
        # Emit terminal/JSON/HTML reporters ONCE at the merged top-level
        # location BEFORE purge_worker_dirs! removes the per-worker
        # `parallel_tests_N` dirs. Earlier behavior had each worker emit
        # reports into its `rspec_tracer_report/parallel_tests_N` dir
        # and the purge then deleted them, leaving the user with zero
        # usable output. Now reporters consume the just-merged
        # top-level snapshot.
        emit_merged_reporters!
        purge_worker_dirs!
        remove_lock_file!
        true
      rescue StandardError => e
        RSpecTracer.logger.warn(
          "RSpec tracer: parallel_tests finalize failed (#{e.class}: #{e.message})"
        )
        false
      end

      # Drop `parallel_tests_N/.rspec_tracer_done` as a flush-complete
      # signal for the elected worker's verification loop. The cache
      # dir already exists by this point (run_finalize mkdir_p's it
      # earlier in the at_exit chain); the explicit mkdir_p here is
      # belt-and-suspenders for the no-examples / early-return paths.
      # Graceful-degradation rescue keeps a marker-write failure from
      # propagating into the user's exit status.
      def self.touch_done!
        ::FileUtils.mkdir_p(RSpecTracer.cache_path)
        ::File.write(
          ::File.join(RSpecTracer.cache_path, DONE_MARKER_FILENAME),
          ::Time.now.utc.iso8601
        )
      rescue StandardError => e
        RSpecTracer.logger.warn(
          "RSpec tracer: failed to write done marker (#{e.class}: #{e.message})"
        )
      end

      # Block until every peer that wrote `.boot` has also written
      # `.done`, or the deadline elapses. Polled at 50ms — fine
      # enough that the typical "barrier returned a tick early" case
      # closes within one or two polls, coarse enough not to dominate
      # CPU.
      #
      # On timeout we log a warn and proceed: a peer that never wrote
      # `.done` either crashed (then its dir is orphan content; the
      # subsequent `purge_worker_dirs!` cleans it) or is genuinely
      # hung (the elected can't fix that — we choose merge correctness
      # over indefinite wait).
      def self.wait_for_peer_done_markers!
        base_dir = ::File.dirname(RSpecTracer.cache_path)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + PEER_DONE_DEADLINE_SECONDS

        loop do
          missing = peer_dirs_missing_done(base_dir)
          return if missing.empty?

          if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
            RSpecTracer.logger.warn(
              'RSpec tracer: peers booted without finishing within ' \
              "#{PEER_DONE_DEADLINE_SECONDS}s: #{missing.inspect}; " \
              'proceeding (peer dirs will be purged regardless of completion state)'
            )
            return
          end

          sleep 0.05
        end
      end

      # Set difference of `.boot`-bearing peer dirs and `.done`-bearing
      # peer dirs under `base_dir`. A returned entry means "this peer
      # registered but hasn't signaled completion yet" — either still
      # mid-flush, or crashed.
      def self.peer_dirs_missing_done(base_dir)
        boot_dirs = peer_dirs_with_marker(base_dir, BOOT_MARKER_FILENAME)
        done_dirs = peer_dirs_with_marker(base_dir, DONE_MARKER_FILENAME)
        boot_dirs - done_dirs
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.peer_dirs_with_marker(base_dir, marker_filename)
        paths = ::Dir.glob(::File.join(base_dir, 'parallel_tests_*', marker_filename))
        paths.map { |path| ::File.dirname(path) }
      end

      # Emit reporters against the merged top-level snapshot
      # so the user gets one terminal summary + one JSON report + one
      # HTML report at the canonical (non-`parallel_tests_N`) path.
      # Wrapped in its own rescue so a failed reporter never blocks
      # purge / lock cleanup downstream.
      def self.emit_merged_reporters!
        return unless RSpecTracer.storage_backend == :json

        base_dir = ::File.dirname(RSpecTracer.cache_path)
        merged_snapshot = load_merged_snapshot(base_dir)
        return if merged_snapshot.nil?

        top_report_dir = ::File.dirname(RSpecTracer.report_path)
        ::FileUtils.mkdir_p(top_report_dir)

        RSpecTracer::Reporters::Registry.emit_all(
          configuration: RSpecTracer,
          snapshot: merged_snapshot,
          report_dir: top_report_dir,
          run_metadata: build_merged_run_metadata(base_dir)
        )
      rescue StandardError => e
        RSpecTracer.logger.warn(
          "RSpec tracer: merged reporter emission failed (#{e.class}: #{e.message})"
        )
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.load_merged_snapshot(base_dir)
        backend = RSpecTracer::Storage::JsonBackend.new(
          cache_path: base_dir,
          logger: RSpecTracer.logger,
          retention_local_count: RSpecTracer.cache_retention_local_count,
          serializer: RSpecTracer.storage_backend_opts[:serializer] || :json
        )
        backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.build_merged_run_metadata(base_dir)
        {
          pid: Process.pid,
          run_time: nil,
          started_at: nil,
          cache_path: base_dir,
          parallel_tests: true,
          rails: RSpecTracer.rails?
        }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.track_test_env_number!
        ::File.open(RSpecTracer.lock_file, ::File::RDWR | ::File::CREAT, 0o644) do |f|
          f.flock(::File::LOCK_EX)

          test_num = [f.read.to_i, ::ENV.fetch('TEST_ENV_NUMBER').to_i].max

          f.rewind
          f.write("#{test_num}\n")
          f.flush
          f.truncate(f.pos)
        end
      end

      # Elects the worker that performs the per-run merge. Delegates to
      # `::ParallelTests.first_process?`, which returns true iff
      # `TEST_ENV_NUMBER.to_i <= 1` -- i.e. for exactly one worker
      # (TEST_ENV_NUMBER == '' or '1'), regardless of how many workers
      # were actually spawned vs. how many CPUs the runner reports.
      #
      # Two historical approaches do NOT work here:
      #
      #   1. The 1.x lock-file scheme (each worker wrote its
      #      TEST_ENV_NUMBER to `rspec_tracer.lock` at RSpecTracer.start
      #      time; last_process? picked the max) deadlocked under CI:
      #      worker 1 could finish its examples before worker 2 even
      #      loaded spec_helper, observe itself as the max, and enter
      #      `wait_for_other_processes_to_finish` concurrently with
      #      worker 2's own self-election -- both workers spun on each
      #      other's pid.
      #
      #   2. `::ParallelTests.last_process?` compares TEST_ENV_NUMBER
      #      against PARALLEL_TEST_GROUPS. parallel_rspec's CLI sets
      #      PARALLEL_TEST_GROUPS to the CPU-based *intended* process
      #      count, NOT the actual worker count -- so when fewer specs
      #      than CPUs are present, no TEST_ENV_NUMBER ever matches
      #      PARALLEL_TEST_GROUPS and the merge is silently skipped.
      #
      # `first_process?` avoids both: it is immutable across worker
      # lifetime (set by the parent at spawn) and identifies exactly
      # one worker regardless of CPU count. The elected worker still
      # calls `wait_for_other_processes_to_finish` before merging, so
      # peer caches are guaranteed on disk by merge time.
      def self.last_process?
        return false unless active?
        return false unless defined?(::ParallelTests)

        ::ParallelTests.first_process?
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remove_lock_file!
        ::FileUtils.rm_f(RSpecTracer.lock_file)
      end

      # parallel_tests sets `PARALLEL_TEST_GROUPS = num_processes.to_s`
      # for each child, where `num_processes` is the user-requested
      # process count (Parallel.processor_count by default) - NOT the
      # number of workers actually spawned. When `num_processes` and
      # the spawned-worker count diverge (e.g. when the spec count caps
      # the partition below the CPU count, or when shared-runner
      # cgroup throttling shifts the visible CPU count between when
      # the parent computed `num_processes` and the spec count is
      # observed), iterating `1..ENV['PARALLEL_TEST_GROUPS']` either
      # over-iterates (cheap; rm_rf on a non-existent path is a no-op)
      # or UNDER-iterates (expensive; merge skips peers + purge leaves
      # `parallel_tests_N` stragglers behind, breaking the integration
      # spec at `spec/integration/parallel_tests_spec.rb:88`).
      #
      # Glob the actual filesystem state rather than reconstructing dir
      # names from an env var with surprising semantics. The directory
      # IS the source of truth for which workers ran. The wait at
      # `finalize!` (`wait_for_other_processes_to_finish`) guarantees
      # every other worker's at_exit has flushed its `parallel_tests_N`
      # tree before this method runs, so the glob captures every peer.
      def self.peer_paths_for(base_dir)
        ::Dir.glob(::File.join(base_dir, 'parallel_tests_*')).select do |path|
          ::File.directory?(path)
        end
      end

      # Merge the per-worker v2 snapshots into the top-level cache.
      # SqliteBackend has no merge surface (single-file, latest-run
      # only); the elected worker persists its own run via Engine
      # finalize and the per-worker files accumulate next to it
      # untouched. The JSON merge path stays authoritative for the
      # default `:json` backend which is what parallel_tests fixtures
      # exercise in CI.
      def self.merge_snapshot!
        return unless RSpecTracer.storage_backend == :json

        base_dir = ::File.dirname(RSpecTracer.cache_path)
        peer_paths = peer_paths_for(base_dir)
        return if peer_paths.empty?

        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        top = RSpecTracer::Storage::JsonBackend.new(
          cache_path: base_dir, logger: RSpecTracer.logger,
          retention_local_count: RSpecTracer.cache_retention_local_count,
          warn_per_file_mb: RSpecTracer.cache_size_warn_per_file_mb,
          warn_total_mb: RSpecTracer.cache_size_warn_total_mb,
          serializer: RSpecTracer.storage_backend_opts[:serializer] || :json
        )
        top.merge_from_peers(peer_paths, schema_version: RSpecTracer::Storage::Schema::CURRENT)

        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

        RSpecTracer.logger.debug("RSpec tracer merged parallel tests reports (took #{elapsed})") if log_rollups?
      end

      # Merge per-worker coverage.json files into a top-level coverage.json.
      # Routed through Reporters::CoverageJsonReporter.merge_parallel
      # (replaces the legacy CoverageMerger + CoverageWriter pair).
      def self.merge_coverage!
        base_dir = ::File.dirname(RSpecTracer.coverage_path)
        peer_paths = peer_paths_for(base_dir)
        return if peer_paths.empty?

        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        RSpecTracer::Reporters::CoverageJsonReporter.merge_parallel(
          peer_paths: peer_paths,
          output_path: ::File.join(base_dir, 'coverage.json'),
          logger: RSpecTracer.logger
        )

        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

        RSpecTracer.logger.debug("RSpec tracer merged parallel tests coverage (took #{elapsed})") if log_rollups?
      end

      # Sweep every `parallel_tests_*` subdirectory under each managed
      # base path. Globbing matches the same source-of-truth contract
      # documented on `peer_paths_for`: the directories that actually
      # exist are exactly the workers that ran, regardless of what
      # PARALLEL_TEST_GROUPS reports.
      def self.purge_worker_dirs!
        [RSpecTracer.cache_path, RSpecTracer.coverage_path, RSpecTracer.report_path].each do |path|
          base_dir = ::File.dirname(path)
          ::Dir.glob(::File.join(base_dir, 'parallel_tests_*')).each do |worker_dir|
            ::FileUtils.rm_rf(worker_dir)
          end
        end
      end
    end
  end
end
