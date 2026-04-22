# frozen_string_literal: true

require 'fileutils'

module RSpecTracer
  module RSpec
    # parallel_tests orchestration for the v2 engine.
    #
    # 1.x scattered the parallel-worker glue across `lib/rspec_tracer.rb`
    # (`parallel_tests_setup`, `track_parallel_tests_test_env_number`,
    # `run_parallel_tests_exit_tasks`, `merge_parallel_tests_reports`,
    # `parallel_tests_last_process?`, etc). M5.1 collapses them here and
    # rewires the snapshot merge onto `Storage::JsonBackend#merge_from_peers`
    # so any storage backend (M3.8 SQLite) gets the merge for free.
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
      LOCK_ENCODING = 'UTF-8'

      module_function

      def active?
        return false if ::ENV.fetch('TEST_ENV_NUMBER', nil).nil?
        return false if ::ENV.fetch('PARALLEL_TEST_GROUPS', nil).nil?

        true
      end

      # Narrator = first process. TEST_ENV_NUMBER is either '' or '1'
      # for the first worker under parallel_tests; otherwise '2', '3',
      # etc. When the gem is not running under parallel_tests, the
      # single process is its own narrator.
      def narrator?
        return true unless active?

        value = ::ENV.fetch('TEST_ENV_NUMBER', '').to_s
        value.empty? || value == '1'
      end

      def verbose?
        ::ENV.fetch('RSPEC_TRACER_VERBOSE', nil) == 'true'
      end

      # True iff this worker should emit rollup log lines. Per-example
      # RSpec output (dots, failures, durations) is unaffected - that's
      # RSpec's own Reporter, not this module.
      def log_rollups?
        verbose? || narrator?
      end

      # Called from RSpecTracer.start when parallel_tests is active.
      # Writes this worker's TEST_ENV_NUMBER into the shared lock file
      # under an exclusive lock so the max-seen value ends up correct
      # regardless of worker boot order.
      def setup!
        return false unless active?

        require 'parallel_tests' unless defined?(::ParallelTests)
        track_test_env_number!
        true
      rescue LoadError => e
        RSpecTracer.logger.error("Failed to load parallel_tests gem (#{e.class}: #{e.message})")
        false
      end

      # Called from at_exit after the per-worker snapshot has been
      # persisted. No-op unless this worker is the designated last
      # process. Orchestrates the snapshot merge, the coverage merge
      # (via the legacy CoverageMerger - coverage.json isn't part of
      # the storage backend's snapshot shape), and the per-worker dir
      # purge.
      def finalize!
        return false unless active?
        return false unless last_process?

        ::ParallelTests.wait_for_other_processes_to_finish if defined?(::ParallelTests)

        merge_snapshot!
        merge_coverage! unless RSpecTracer.simplecov?
        purge_worker_dirs!
        remove_lock_file!
        true
      rescue StandardError => e
        RSpecTracer.logger.warn(
          "RSpec tracer: parallel_tests finalize failed (#{e.class}: #{e.message})"
        )
        false
      end

      def track_test_env_number!
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
      # `TEST_ENV_NUMBER.to_i <= 1` — i.e. for exactly one worker
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
      #      worker 2's own self-election — both workers spun on each
      #      other's pid.
      #
      #   2. `::ParallelTests.last_process?` compares TEST_ENV_NUMBER
      #      against PARALLEL_TEST_GROUPS. parallel_rspec's CLI sets
      #      PARALLEL_TEST_GROUPS to the CPU-based *intended* process
      #      count, NOT the actual worker count — so when fewer specs
      #      than CPUs are present, no TEST_ENV_NUMBER ever matches
      #      PARALLEL_TEST_GROUPS and the merge is silently skipped.
      #
      # `first_process?` avoids both: it is immutable across worker
      # lifetime (set by the parent at spawn) and identifies exactly
      # one worker regardless of CPU count. The elected worker still
      # calls `wait_for_other_processes_to_finish` before merging, so
      # peer caches are guaranteed on disk by merge time.
      def last_process?
        return false unless active?
        return false unless defined?(::ParallelTests)

        ::ParallelTests.first_process?
      end

      def remove_lock_file!
        ::FileUtils.rm_f(RSpecTracer.lock_file)
      end

      def worker_group_count
        ::ENV.fetch('PARALLEL_TEST_GROUPS', '0').to_i
      end

      def peer_paths_for(base_dir)
        (1..worker_group_count).filter_map do |n|
          path = ::File.join(base_dir, "parallel_tests_#{n}")
          path if ::File.directory?(path)
        end
      end

      # Merge the per-worker v2 snapshots into the top-level cache.
      def merge_snapshot!
        base_dir = ::File.dirname(RSpecTracer.cache_path)
        peer_paths = peer_paths_for(base_dir)
        return if peer_paths.empty?

        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        top = RSpecTracer::Storage::JsonBackend.new(cache_path: base_dir, logger: RSpecTracer.logger)
        top.merge_from_peers(peer_paths, schema_version: RSpecTracer::Storage::Schema::CURRENT)

        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

        RSpecTracer.logger.debug("RSpec tracer merged parallel tests reports (took #{elapsed})") if log_rollups?
      end

      # Merge per-worker coverage.json files into a top-level coverage.json.
      def merge_coverage!
        base_dir = ::File.dirname(RSpecTracer.coverage_path)
        peer_paths = peer_paths_for(base_dir)
        return if peer_paths.empty?

        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        merger = RSpecTracer::CoverageMerger.new
        merger.merge(peer_paths)

        file_name = ::File.join(base_dir, 'coverage.json')
        coverage_writer = RSpecTracer::CoverageWriter.new(file_name, merger)
        coverage_writer.write_report

        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

        RSpecTracer.logger.debug("RSpec tracer merged parallel tests coverage (took #{elapsed})") if log_rollups?
      end

      def purge_worker_dirs!
        [RSpecTracer.cache_path, RSpecTracer.coverage_path, RSpecTracer.report_path].each do |path|
          base_dir = ::File.dirname(path)
          (1..worker_group_count).each do |n|
            ::FileUtils.rm_rf(::File.join(base_dir, "parallel_tests_#{n}"))
          end
        end
      end
    end
  end
end
