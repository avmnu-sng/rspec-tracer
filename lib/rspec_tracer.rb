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
require_relative 'rspec_tracer/engine'
require_relative 'rspec_tracer/example'
# Reporters must load before load_config so the Configuration DSL's
# `add_reporter` can validate symbol names against
# `Reporters::Registry::BUILT_INS` when a user `.rspec-tracer` calls
# it at configure time (M6.1).
require_relative 'rspec_tracer/reporters/base'
require_relative 'rspec_tracer/reporters/payload_builder'
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
require_relative 'rspec_tracer/ruby_coverage'
require_relative 'rspec_tracer/source_file'
require_relative 'rspec_tracer/time_formatter'
require_relative 'rspec_tracer/version'

# Top-level entry point. Drives the M5.1 lifecycle:
#
#   RSpecTracer.start
#     → RSpec::Installation.install!  (prepend RunnerHook + ReporterHook)
#     → setup_coverage                (::Coverage.start unless SimpleCov owns it)
#     → setup_rails                   (detect ::Rails::VERSION)
#     → Engine.new.setup              (observers + cache load + filter decisions)
#     → coverage_reporter             (coverage.json emission)
#
#   at_exit_behavior (installed via `at_exit` elsewhere in the boot
#   flow) runs the finalize stack: Engine#finalize writes the 13-file
#   snapshot via Storage::JsonBackend, coverage_reporter writes
#   coverage.json, ParallelTests#finalize! merges per-worker caches
#   on the last worker.
module RSpecTracer
  class << self
    attr_accessor :running, :pid, :no_examples, :duplicate_examples

    def start
      return if defined?(@started) && @started

      RSpecTracer.running = false
      RSpecTracer.pid = Process.pid
      @run_started_at = ::Time.now.utc
      @run_monotonic_start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      @started = true

      RSpecTracer.logger.debug "Started RSpec tracer (pid: #{RSpecTracer.pid})"

      @parallel_tests = RSpecTracer::RSpec::ParallelTests.active?
      RSpecTracer::RSpec::ParallelTests.setup! if parallel_tests?
      initial_setup
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

    def coverage_reporter
      @coverage_reporter if defined?(@coverage_reporter)
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
      @coverage_reporter = RSpecTracer::CoverageReporter.new
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
        emit_reporters(snapshot) if snapshot
      end

      simplecov? ? run_simplecov_exit_task : run_coverage_exit_task

      RSpecTracer::RSpec::ParallelTests.finalize! if parallel_tests?
    end

    # Engine-owned finalize path. Engine writes the 15-file JSON cache
    # via Storage::JsonBackend; CoverageReporter still owns the
    # coverage.json surface (M3.6 Decision 2 - reporter rework lives in
    # Phase 6). The two paths share per-example coverage deltas via
    # `merge_skipped_coverage`: skipped examples' prior-run coverage
    # rolls forward into coverage.json so missed_coverage semantics
    # match 1.x.
    def run_finalize
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_reporter.generate_final_examples_coverage
      skipped_ids = engine.registry.ids_with_status(:skipped)
      coverage_reporter.merge_coverage(engine.merge_skipped_coverage(skipped_ids))
      snapshot = engine.finalize

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer persisted cache (took #{elapsed})"
      snapshot
    rescue StandardError => e
      # Graceful-degradation contract per docs/revamp/ARCHITECTURE.md
      # §Cache corruption recovery: never propagate storage errors
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
  end
end
