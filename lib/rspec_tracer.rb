# frozen_string_literal: true

require 'English'

require 'digest/md5'
require 'docile'
require 'fileutils'
require 'forwardable'
require 'json'
require 'pathname'
require 'set'

require_relative 'rspec_tracer/coverage_merger'
require_relative 'rspec_tracer/coverage_reporter'
require_relative 'rspec_tracer/coverage_writer'
require_relative 'rspec_tracer/defaults'
require_relative 'rspec_tracer/example'
require_relative 'rspec_tracer/html_reporter/reporter'
require_relative 'rspec_tracer/load_config'
require_relative 'rspec_tracer/remote_cache/cache'
require_relative 'rspec_tracer/report_generator'
require_relative 'rspec_tracer/report_merger'
require_relative 'rspec_tracer/report_writer'
require_relative 'rspec_tracer/rspec_reporter'
require_relative 'rspec_tracer/rspec_runner'
require_relative 'rspec_tracer/ruby_coverage'
require_relative 'rspec_tracer/runner'
require_relative 'rspec_tracer/source_file'
require_relative 'rspec_tracer/time_formatter'
require_relative 'rspec_tracer/version'

module RSpecTracer
  # Filesystem barrier markers, layered on top of parallel_tests's
  # pid-file wait to defend against the GHA-observed race where the
  # gem's `wait_for_other_processes_to_finish` returns while a sibling
  # worker hasn't fully flushed its `parallel_tests_N/` dir yet. Each
  # worker writes BOOT at setup-time and DONE as the first step of its
  # at_exit tasks; the elected worker waits for every booted peer's
  # DONE marker (deadline-bounded) before proceeding to merge + purge.
  PARALLEL_TESTS_BOOT_MARKER_FILENAME = '.rspec_tracer_boot'
  PARALLEL_TESTS_DONE_MARKER_FILENAME = '.rspec_tracer_done'
  PARALLEL_TESTS_PEER_DONE_DEADLINE_SECONDS = 5

  class << self
    attr_accessor :running, :pid, :no_examples, :duplicate_examples

    def start
      RSpecTracer.running = false
      RSpecTracer.pid = Process.pid

      return if RUBY_ENGINE == 'jruby' && !valid_jruby_opts?

      RSpecTracer.logger.debug "Started RSpec tracer (pid: #{RSpecTracer.pid})"

      parallel_tests_setup
      initial_setup
    end

    # rubocop:disable Metrics/AbcSize
    def filter_examples
      groups = Set.new
      to_run = Hash.new { |hash, group| hash[group] = [] }

      RSpec.world.filtered_examples.each_pair do |example_group, examples|
        examples.each do |example|
          tracer_example = RSpecTracer::Example.from(example)
          example_id = tracer_example[:example_id]
          example.metadata[:rspec_tracer_example_id] = example_id

          if runner.run_example?(example_id)
            run_reason = runner.run_example_reason(example_id)
            tracer_example[:run_reason] = run_reason
            example.metadata[:description] = "#{example.description} (#{run_reason})"

            to_run[example_group] << example
            groups << example.example_group.parent_groups.last

            runner.register_example(tracer_example)
          else
            runner.on_example_skipped(example_id)
          end
        end
      end

      runner.deregister_duplicate_examples

      [to_run, groups.to_a]
    end
    # rubocop:enable Metrics/AbcSize

    def at_exit_behavior
      return unless RSpecTracer.pid == Process.pid && RSpecTracer.running

      ::Kernel.exit(1) if duplicate_examples

      run_exit_tasks
    ensure
      FileUtils.rm_f(RSpecTracer.lock_file) if parallel_tests_last_process?

      RSpecTracer.running = false
    end

    def start_example_trace
      trace_point.enable
    end

    def stop_example_trace(example_id)
      trace_point.disable

      @examples_traced_files[example_id] = @traced_files
      @traced_files = Set.new
    end

    def runner
      @runner if defined?(@runner)
    end

    def coverage_reporter
      @coverage_reporter if defined?(@coverage_reporter)
    end

    def report_writer
      @report_writer if defined?(@report_writer)
    end

    def coverage_merger
      @coverage_merger if defined?(@coverage_merger)
    end

    def report_merger
      @report_merger if defined?(@report_merger)
    end

    def trace_point
      @trace_point if defined?(@trace_point)
    end

    def traced_files
      @traced_files if defined?(@traced_files)
    end

    def examples_traced_files
      @examples_traced_files if defined?(@examples_traced_files)
    end

    def simplecov?
      defined?(@simplecov) && @simplecov == true
    end

    def parallel_tests?
      defined?(@parallel_tests) && @parallel_tests == true
    end

    private

    def valid_jruby_opts?
      require 'jruby'

      return true if Java::OrgJruby::RubyInstanceConfig.FULL_TRACE_ENABLED &&
        JRuby.runtime.object_space_enabled?

      RSpecTracer.logger.warn <<-WARN.strip.gsub(/\s+/, ' ')
        RSpec Tracer is not running as it requires debug and object space enabled. Use
        command line options "--debug" and "-X+O" or set the "debug.fullTrace=true" and
        "objectspace.enabled=true" options in your .jrubyrc file. You can also use
        JRUBY_OPTS="--debug -X+O".
      WARN

      false
    end

    def initial_setup
      unless setup_rspec?
        RSpecTracer.logger.error 'Could not find a running RSpec process'

        return
      end

      setup_coverage
      setup_trace_point

      @runner = RSpecTracer::Runner.new
      @coverage_reporter = RSpecTracer::CoverageReporter.new
      @report_writer = RSpecTracer::ReportWriter.new(RSpecTracer.cache_path, @runner.reporter)
    end

    def parallel_tests_setup
      @parallel_tests = !(ENV.fetch('TEST_ENV_NUMBER', nil) && ENV.fetch('PARALLEL_TEST_GROUPS', nil)).nil?

      return unless parallel_tests?

      require 'parallel_tests' unless defined?(ParallelTests)

      @coverage_merger = RSpecTracer::CoverageMerger.new
      @report_merger = RSpecTracer::ReportMerger.new
    rescue LoadError => e
      RSpecTracer.logger.error "Failed to load parallel tests (Error: #{e.message})"
    ensure
      track_parallel_tests_test_env_number
      parallel_tests_touch_boot!
    end

    # Per-worker boot marker. Source-of-truth for "this worker booted
    # past `RSpecTracer.start`", consumed by the elected worker's
    # finalize-time peer enumeration. Idempotent; failures are warned
    # and absorbed (boot-marker write must never block test execution).
    def parallel_tests_touch_boot!
      return unless parallel_tests?

      FileUtils.mkdir_p(RSpecTracer.cache_path)
      File.write(
        File.join(RSpecTracer.cache_path, PARALLEL_TESTS_BOOT_MARKER_FILENAME),
        JSON.generate(
          pid: Process.pid,
          test_env_number: ENV.fetch('TEST_ENV_NUMBER', ''),
          started_at: Time.now.utc.iso8601
        )
      )
    rescue StandardError => e
      RSpecTracer.logger.warn(
        "RSpec tracer: failed to write boot marker (#{e.class}: #{e.message})"
      )
    end

    def track_parallel_tests_test_env_number
      return unless parallel_tests?

      File.open(RSpecTracer.lock_file, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)

        test_num = [f.read.to_i, ENV['TEST_ENV_NUMBER'].to_i].max

        f.rewind
        f.write("#{test_num}\n")
        f.flush
        f.truncate(f.pos)
      end
    end

    def setup_rspec?
      runners = ObjectSpace.each_object(::RSpec::Core::Runner) do |runner|
        runner_clazz = runner.singleton_class
        clazz = RSpecTracer::RSpecRunner

        runner_clazz.prepend(clazz) unless runner_clazz.ancestors.include?(clazz)

        reporter_clazz = runner.configuration.reporter.singleton_class
        clazz = RSpecTracer::RSpecReporter

        reporter_clazz.prepend(clazz) unless reporter_clazz.ancestors.include?(clazz)
      end

      runners.positive?
    end

    def setup_coverage
      @simplecov = defined?(SimpleCov) && SimpleCov.running

      return if simplecov?

      require 'coverage'

      ::Coverage.start
    end

    def setup_trace_point
      @traced_files = Set.new
      @examples_traced_files = {}

      @trace_point = TracePoint.new(:call) do |tp|
        RSpecTracer.traced_files << tp.path if tp.path.start_with?(RSpecTracer.root)
      end
    end

    def run_exit_tasks
      if RSpecTracer.no_examples
        RSpecTracer.logger.info 'Skipped reports generation since all examples were filtered out'
      else
        generate_reports
      end

      simplecov? ? run_simplecov_exit_task : run_coverage_exit_task

      run_parallel_tests_exit_tasks
    end

    def generate_reports
      RSpecTracer.logger.debug "RSpec tracer is generating reports (pid: #{RSpecTracer.pid})"

      process_dependency
      process_coverage

      RSpecTracer::ReportGenerator.new(runner.reporter, runner.cache).generate_report
      report_writer.write_report
      RSpecTracer::HTMLReporter::Reporter.new(RSpecTracer.report_path, runner.reporter).generate_report
    end

    def process_dependency
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      runner.register_interrupted_examples
      runner.register_deleted_examples
      runner.register_dependency(coverage_reporter.examples_coverage)
      runner.register_traced_dependency(@examples_traced_files)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer processed dependency (took #{elapsed})"
    end

    def process_coverage
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_reporter.generate_final_examples_coverage
      coverage_reporter.merge_coverage(runner.generate_missed_coverage)
      runner.register_examples_coverage(coverage_reporter.examples_coverage)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer processed coverage (took #{elapsed})"
    end

    def run_simplecov_exit_task
      coverage_clazz = ::Coverage.singleton_class
      clazz = RSpecTracer::RubyCoverage
      coverage_clazz.prepend(clazz) unless coverage_clazz.ancestors.include?(clazz)

      RSpecTracer.logger.debug 'SimpleCov will now generate coverage report (<3 RSpec tracer)'

      coverage_reporter.record_coverage if RSpecTracer.no_examples
    end

    def run_coverage_exit_task
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_reporter.record_coverage if RSpecTracer.no_examples
      coverage_reporter.generate_final_coverage

      file_name = File.join(RSpecTracer.coverage_path, 'coverage.json')
      coverage_writer = RSpecTracer::CoverageWriter.new(file_name, coverage_reporter)

      coverage_writer.write_report

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_writer.print_stats(ending - starting)
    end

    def run_parallel_tests_exit_tasks
      # Every worker — elected or not — drops its `.done` marker as the
      # first thing in finalize so the elected worker's
      # `parallel_tests_wait_for_peer_done_markers!` can observe it.
      # Non-elected workers stop here; the elected worker proceeds to
      # the merge + purge sequence (gated by `parallel_tests_executed?`,
      # which now layers the peer-done barrier on top of the existing
      # pid-file wait).
      parallel_tests_touch_done!

      return unless parallel_tests_executed?

      merge_parallel_tests_reports
      write_parallel_tests_merged_report
      merge_parallel_tests_coverage_reports
      write_parallel_tests_coverage_report
      purge_parallel_tests_reports
    end

    # Per-worker done marker. Written by every worker (elected or not)
    # as the first step of `run_parallel_tests_exit_tasks`. Pairs with
    # the boot marker for the elected worker's peer-done barrier:
    # presence of `.done` means "this worker has signalled completion
    # of its own writes"; absence (with `.boot` present) means "still
    # mid-flush or crashed". Idempotent; failures are warned + absorbed.
    def parallel_tests_touch_done!
      return unless parallel_tests?

      FileUtils.mkdir_p(RSpecTracer.cache_path)
      File.write(
        File.join(RSpecTracer.cache_path, PARALLEL_TESTS_DONE_MARKER_FILENAME),
        Time.now.utc.iso8601
      )
    rescue StandardError => e
      RSpecTracer.logger.warn(
        "RSpec tracer: failed to write done marker (#{e.class}: #{e.message})"
      )
    end

    def merge_parallel_tests_reports
      return unless parallel_tests_executed?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reports_dir = []

      parallel_tests_peer_dirs(File.dirname(RSpecTracer.cache_path)).each do |cache_dir|
        run_id = JSON.parse(File.read(File.join(cache_dir, 'last_run.json'), encoding: 'UTF-8'))['run_id']

        reports_dir << File.join(cache_dir, run_id)
      end

      report_merger.merge(reports_dir)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer merged parallel tests reports (took #{elapsed})"
    end

    def write_parallel_tests_merged_report
      return unless parallel_tests_executed?

      report_dir = File.dirname(RSpecTracer.cache_path)

      RSpecTracer::ReportWriter.new(report_dir, report_merger).write_report

      report_dir = File.dirname(RSpecTracer.report_path)

      RSpecTracer::HTMLReporter::Reporter.new(report_dir, report_merger).generate_report
    end

    def merge_parallel_tests_coverage_reports
      return unless parallel_tests_executed? && !simplecov?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      reports_dir = parallel_tests_peer_dirs(File.dirname(RSpecTracer.coverage_path))

      coverage_merger.merge(reports_dir)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer merged parallel tests coverage reports (took #{elapsed})"
    end

    def write_parallel_tests_coverage_report
      return unless parallel_tests_executed? && !simplecov?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_path = File.dirname(RSpecTracer.coverage_path)
      file_name = File.join(coverage_path, 'coverage.json')
      coverage_writer = RSpecTracer::CoverageWriter.new(file_name, coverage_merger)

      coverage_writer.write_report

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_writer.print_stats(ending - starting)
    end

    def purge_parallel_tests_reports
      return unless parallel_tests_executed?

      [RSpecTracer.cache_path, RSpecTracer.coverage_path, RSpecTracer.report_path].each do |path|
        parallel_tests_peer_dirs(File.dirname(path)).each do |worker_dir|
          FileUtils.rm_rf(worker_dir)
        end
      end
    end

    # Returns every `parallel_tests_*` subdirectory directly under
    # `base_path`. Used by the parallel_tests merge + purge paths.
    #
    # Earlier patches iterated `1..ENV['PARALLEL_TEST_GROUPS'].to_i`
    # to construct dir names, but parallel_tests's own runner sets
    # PARALLEL_TEST_GROUPS to the user-requested process count
    # (`Parallel.processor_count` by default), NOT the actual worker
    # count. When num_processes < spawned_worker_count, the upper
    # bound was too small: peer caches with TEST_ENV_NUMBER above the
    # bound were silently dropped from the merge AND left behind by
    # the purge. PR #101's commit message documented this gem
    # behaviour for `last_process?` detection but did not extend the
    # fix to the iteration call-sites; this method closes that gap.
    # Globbing the actual filesystem state is robust to the env
    # discrepancy regardless of how the gem partitions specs.
    def parallel_tests_peer_dirs(base_path)
      Dir.glob(File.join(base_path, 'parallel_tests_*')).select do |path|
        File.directory?(path)
      end
    end

    def parallel_tests_executed?
      return false unless parallel_tests? && parallel_tests_last_process?

      ParallelTests.wait_for_other_processes_to_finish

      # Belt-and-suspenders barrier: pid-file said everyone's done, but
      # the gem's `wait_for_other_processes_to_finish` has been observed
      # on GHA Linux x86_64 to return while a sibling's `parallel_tests_N/`
      # is still mid-flush. Cross-check via the `.boot`/`.done` filesystem
      # markers before declaring the peer set stable. Idempotent: once
      # all peers have flushed, subsequent calls just glob, find nothing
      # missing, and return.
      parallel_tests_wait_for_peer_done_markers!

      true
    end

    # Block until every peer that wrote `.boot` has also written `.done`,
    # or the deadline elapses. Polled at 50ms — fine enough to close the
    # typical "barrier returned a tick early" case within a poll or two,
    # coarse enough not to dominate CPU.
    #
    # On timeout we log a warn and proceed: a peer that never wrote
    # `.done` either crashed (then its dir is orphan content; the
    # subsequent purge cleans it) or is genuinely hung (the elected
    # can't fix that — we choose merge correctness over indefinite wait).
    def parallel_tests_wait_for_peer_done_markers!
      base_dir = File.dirname(RSpecTracer.cache_path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PARALLEL_TESTS_PEER_DONE_DEADLINE_SECONDS

      loop do
        missing = parallel_tests_peer_dirs_missing_done(base_dir)
        return if missing.empty?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          RSpecTracer.logger.warn(
            'RSpec tracer: peers booted without finishing within ' \
            "#{PARALLEL_TESTS_PEER_DONE_DEADLINE_SECONDS}s: #{missing.inspect}; " \
            'proceeding (peer dirs will be purged regardless of completion state)'
          )
          return
        end

        sleep 0.05
      end
    end

    # Set difference of `.boot`-bearing peer dirs and `.done`-bearing
    # peer dirs under `base_dir`. A returned entry means "this peer
    # registered but has not signalled completion yet" — either still
    # mid-flush or crashed.
    def parallel_tests_peer_dirs_missing_done(base_dir)
      boot_dirs = parallel_tests_peer_dirs_with_marker(base_dir, PARALLEL_TESTS_BOOT_MARKER_FILENAME)
      done_dirs = parallel_tests_peer_dirs_with_marker(base_dir, PARALLEL_TESTS_DONE_MARKER_FILENAME)
      boot_dirs - done_dirs
    end

    def parallel_tests_peer_dirs_with_marker(base_dir, marker_filename)
      Dir.glob(File.join(base_dir, 'parallel_tests_*', marker_filename)).map do |path|
        File.dirname(path)
      end
    end

    # Elects the worker that performs the per-run merge. Delegates to
    # `::ParallelTests.first_process?`, which returns true iff
    # `TEST_ENV_NUMBER.to_i <= 1` — i.e. for exactly one worker
    # (TEST_ENV_NUMBER == '' or '1'), regardless of how many workers
    # were actually spawned vs. how many CPUs the runner reports.
    #
    # Two previously attempted approaches do NOT work here:
    #
    #   1. The lock-file scheme below (each worker writing its
    #      TEST_ENV_NUMBER to `rspec_tracer.lock` via
    #      `track_parallel_tests_test_env_number`; last_process picked
    #      the max) deadlocked under slow CI: worker 1 could finish
    #      its examples before worker 2 even loaded spec_helper,
    #      observe itself as the max, and enter
    #      `::ParallelTests.wait_for_other_processes_to_finish`
    #      concurrently with worker 2's own self-election — both
    #      workers then spun on each other's pid.
    #
    #   2. `::ParallelTests.last_process?` compares TEST_ENV_NUMBER
    #      against PARALLEL_TEST_GROUPS, which parallel_rspec sets to
    #      the CPU-based *intended* process count — NOT the actual
    #      worker count. When spec files < CPU count (common), no
    #      TEST_ENV_NUMBER ever matches PARALLEL_TEST_GROUPS and the
    #      merge is silently skipped.
    #
    # `first_process?` avoids both: set by the parent at spawn,
    # immutable thereafter, and identifies exactly one worker
    # regardless of CPU count. The elected worker still calls
    # `wait_for_other_processes_to_finish` before merging so peer
    # caches are guaranteed on disk.
    #
    # `track_parallel_tests_test_env_number` and the lock-file
    # cleanup in `at_exit_behavior` are retained for backward
    # compatibility with users who observe `rspec_tracer.lock` /
    # set `RSPEC_TRACER_LOCK_FILE`; the file is still written and
    # removed but is no longer consulted.
    def parallel_tests_last_process?
      return false unless parallel_tests?
      return false unless defined?(::ParallelTests)

      ::ParallelTests.first_process?
    end
  end
end
