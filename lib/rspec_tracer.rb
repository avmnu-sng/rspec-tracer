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
require_relative 'rspec_tracer/load_config'
require_relative 'rspec_tracer/remote_cache/cache'
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
        run_finalize
      end

      simplecov? ? run_simplecov_exit_task : run_coverage_exit_task

      RSpecTracer::RSpec::ParallelTests.finalize! if parallel_tests?
    end

    # Engine-owned finalize path. Engine writes the 13-file JSON cache
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
      engine.finalize

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer persisted cache (took #{elapsed})"
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
