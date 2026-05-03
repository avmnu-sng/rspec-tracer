# frozen_string_literal: true

require 'English'

require 'digest/md5'
require 'docile'
require 'fileutils'
require 'forwardable'
require 'json'
require 'pathname'
require 'set'

require_relative 'rspec_tracer/defaults'
require_relative 'rspec_tracer/engine'
require_relative 'rspec_tracer/example'
# Reporters must load before load_config so the Configuration DSL's
# `add_reporter` can validate symbol names against
# `Reporters::Registry::BUILT_INS` when a user `.rspec-tracer` calls
# it at configure time (M6.1).
require_relative 'rspec_tracer/reporters/base'
require_relative 'rspec_tracer/reporters/payload_builder'
require_relative 'rspec_tracer/reporters/coverage_json_reporter'
require_relative 'rspec_tracer/reporters/json_reporter'
require_relative 'rspec_tracer/reporters/terminal_reporter'
require_relative 'rspec_tracer/reporters/html_reporter'
require_relative 'rspec_tracer/reporters/registry'
require_relative 'rspec_tracer/load_config'
# RemoteCache is loaded lazily from its Rakefile shim (user-driven),
# not at gem-load time. The user-facing tasks `rspec_tracer:remote_cache:*`
# pull in `lib/rspec_tracer/remote_cache.rb` when the user's Rakefile
# loads the shim. Test-suite runs that never invoke a cache task pay
# zero load cost for aws/git subshell code.
require_relative 'rspec_tracer/rspec/installation'
require_relative 'rspec_tracer/rspec/parallel_tests'
require_relative 'rspec_tracer/source_file'
require_relative 'rspec_tracer/time_formatter'
require_relative 'rspec_tracer/version'

# Top-level entry point. Drives the M5.1 lifecycle:
#
#   RSpecTracer.start
#     -> RSpec::Installation.install!  (prepend RunnerHook + ReporterHook)
#     -> setup_coverage                (::Coverage.start unless SimpleCov owns it)
#     -> setup_rails                   (detect ::Rails::VERSION)
#     -> Engine.new.setup              (observers + cache load + filter decisions)
#
#   at_exit_behavior (installed via `at_exit` elsewhere in the boot
#   flow) runs the finalize stack: Engine#finalize writes the 13-file
#   snapshot via Storage::JsonBackend, Reporters::CoverageJsonReporter
#   writes coverage.json (single owner, replacing the 1.x
#   CoverageReporter + CoverageWriter pair retired in M8.0),
#   ParallelTests#finalize! merges per-worker caches on the last worker.
module RSpecTracer
  class << self
    attr_accessor :running, :pid, :no_examples, :duplicate_examples

    # Boot the tracer. Idempotent — safe to call multiple times in a
    # single process (subsequent calls return without re-installing
    # hooks). Drives the lifecycle:
    #
    #   * Installs the RSpec runner / reporter prepend chain.
    #   * Starts `::Coverage` unless SimpleCov already owns it.
    #   * Detects Rails (memoized in `RSpecTracer.rails?`).
    #   * Builds the {RSpecTracer::Engine} and installs observers.
    #
    # Must be called BEFORE any application code loads so the boot
    # set captured by `Coverage.peek_result` is empty. With SimpleCov,
    # call `SimpleCov.start` first; rspec-tracer warns at boot when
    # SimpleCov is loaded but not started.
    #
    # @return [void]
    def start
      return if defined?(@started) && @started

      RSpecTracer.running = false
      RSpecTracer.pid = Process.pid
      @run_started_at = ::Time.now.utc
      @run_monotonic_start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      @started = true

      RSpecTracer.logger.debug "Started RSpec tracer (pid: #{RSpecTracer.pid})"

      warn_on_simplecov_load_order_mistake

      @parallel_tests = RSpecTracer::RSpec::ParallelTests.active?
      RSpecTracer::RSpec::ParallelTests.setup! if parallel_tests?
      initial_setup
    end

    # M8.9: SimpleCov load-order is part of the documented contract -
    # SimpleCov.start MUST run before RSpecTracer.start when both are
    # used together (see README §SimpleCov interop). When the user
    # has SimpleCov loaded but not started, we'd silently call
    # ::Coverage.start ourselves and SimpleCov's later setup would
    # bolt onto a Coverage already in flight, with the user's
    # add_filter calls applied after rspec-tracer started consuming
    # data. Surface the load-order mistake at start time so the user
    # gets a one-line warning instead of mysteriously-broken
    # coverage output.
    def warn_on_simplecov_load_order_mistake
      return unless defined?(::SimpleCov)
      return if ::SimpleCov.respond_to?(:running) && ::SimpleCov.running

      RSpecTracer.logger.warn(
        'SimpleCov is loaded but not started. ' \
        'Call SimpleCov.start before RSpecTracer.start so the ' \
        'tracer respects SimpleCov\'s filter chain. See README ' \
        'section "Working with SimpleCov".'
      )
    end

    def at_exit_behavior
      return unless RSpecTracer.pid == Process.pid && RSpecTracer.running

      ::Kernel.exit(1) if duplicate_examples

      run_exit_tasks
    ensure
      if RSpecTracer::RSpec::ParallelTests.active? &&
          RSpecTracer::RSpec::ParallelTests.last_process?
        RSpecTracer::RSpec::ParallelTests.remove_lock_file!
      end

      RSpecTracer.running = false
    end

    def engine
      @engine if defined?(@engine)
    end

    def simplecov?
      defined?(@simplecov) && @simplecov == true
    end

    def parallel_tests?
      defined?(@parallel_tests) && @parallel_tests == true
    end

    # True iff Rails is loaded in this process. Computed once during
    # `initial_setup` (via `setup_rails`) and memoized; subsequent Rails
    # activations within the same run are not re-detected. Matches the
    # `simplecov?` / `parallel_tests?` shape so callers can branch on
    # framework presence uniformly.
    def rails?
      defined?(@rails) && @rails == true
    end

    private

    def initial_setup
      RSpecTracer::RSpec::Installation.install!

      setup_coverage
      setup_rails

      @engine = RSpecTracer::Engine.new(configuration: RSpecTracer)
      @engine.setup
    end

    def setup_coverage
      @simplecov = defined?(SimpleCov) && SimpleCov.running

      return if simplecov?

      require 'coverage'

      ::Coverage.start
    end

    # Detects Rails by the presence of `::Rails::VERSION`. Users who
    # require `rspec_tracer/rails` transitively load the Railtie (when
    # Rails is also present); this method only sets the flag consumed
    # by `RSpecTracer.rails?`. Safe when Rails is absent - the
    # `defined?` guard returns nil, flag stays false.
    def setup_rails
      @rails = defined?(::Rails::VERSION) && !::Rails::VERSION.nil?
    end

    def run_exit_tasks
      if RSpecTracer.no_examples
        RSpecTracer.logger.info 'Skipped reports generation since all examples were filtered out'
      else
        snapshot = run_finalize
        # M8.10: under parallel_tests, defer reporter emission until
        # last-process finalize merges per-worker snapshots into the
        # top-level cache. Each worker still persists its per-worker
        # snapshot for the merge to consume. Pre-M8.10 every worker
        # emitted reporters into rspec_tracer_report/parallel_tests_N/
        # and purge_worker_dirs! removed those dirs - leaving the user
        # with no usable terminal/JSON/HTML output. Now reporters fire
        # ONCE at the merged top-level location (3x v1 orphan: M6.2 +
        # M7.1 + M7.2).
        emit_reporters(snapshot) if snapshot && !parallel_tests?
      end

      emit_coverage_json

      RSpecTracer::RSpec::ParallelTests.finalize! if parallel_tests?
    end

    # Engine-owned finalize path. Writes the 15-file JSON cache via
    # Storage::JsonBackend. Per-example coverage deltas live on the
    # Engine; M8.0 retired the CoverageReporter mid-flow piece (the
    # legacy `coverage_reporter.generate_final_examples_coverage +
    # merge_coverage(engine.merge_skipped_coverage(...))` is now folded
    # into Reporters::CoverageJsonReporter#generate, which fires from
    # `emit_coverage_json` after this method returns).
    def run_finalize
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      snapshot = engine.finalize

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer persisted cache (took #{elapsed})"
      snapshot
    rescue StandardError => e
      # Graceful-degradation contract per ARCHITECTURE.md
      # section Cache corruption recovery: never propagate storage errors
      # into the user's test suite. Read-only cache_path, disk-full
      # mid-write, permission flips between runs - log and skip
      # report emission. The caller (run_exit_tasks) checks for nil
      # before calling emit_reporters; coverage / parallel_tests
      # finalize paths run independently downstream.
      RSpecTracer.logger.warn(
        "rspec-tracer: cache persistence failed (#{e.class}: #{e.message}); " \
        'skipping report generation. Verify cache_path is writable.'
      )
      nil
    end

    # M6.1. Fire the configured reporters against the persisted
    # Snapshot. Fires per-worker under parallel_tests (same cadence as
    # coverage.json emission); each worker produces its own report.json
    # under its per-worker report_dir. The Registry rescues every
    # reporter individually, so a buggy reporter warns and continues -
    # never propagates a non-zero exit into the user's test suite
    # (graceful degradation contract, same as Storage backends).
    def emit_reporters(snapshot)
      RSpecTracer::Reporters::Registry.emit_all(
        configuration: RSpecTracer,
        snapshot: snapshot,
        report_dir: RSpecTracer.report_path,
        run_metadata: build_run_metadata
      )
    rescue StandardError => e
      RSpecTracer.logger.warn(
        "rspec-tracer: reporter pipeline failed (#{e.class}: #{e.message})"
      )
    end

    def build_run_metadata
      {
        pid: RSpecTracer.pid,
        run_time: run_elapsed_seconds,
        started_at: defined?(@run_started_at) ? @run_started_at : nil,
        cache_path: RSpecTracer.cache_path,
        parallel_tests: RSpecTracer.parallel_tests?,
        rails: RSpecTracer.rails?
      }
    end

    def run_elapsed_seconds
      return nil unless defined?(@run_monotonic_start) && @run_monotonic_start

      (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - @run_monotonic_start).round(4)
    end

    # M8.0: dedicated coverage.json firing path, parallel to the
    # report-reporters Registry pipeline. Fires unconditionally - even
    # when no examples ran (matches 1.x where coverage.json gets
    # written with whatever boot-time peek_result returned + filter +
    # stub). The emitter handles SimpleCov interop internally
    # (installs `::Coverage.singleton_class.prepend` shim instead of
    # writing coverage.json when SimpleCov is loaded).
    def emit_coverage_json
      return unless engine

      RSpecTracer::Reporters::CoverageJsonReporter.new(
        snapshot: nil,
        report_dir: RSpecTracer.report_path,
        run_metadata: build_run_metadata,
        logger: RSpecTracer.logger
      ).generate
    rescue StandardError => e
      RSpecTracer.logger.warn(
        "rspec-tracer: coverage.json emit failed (#{e.class}: #{e.message})"
      )
    end
  end
end
