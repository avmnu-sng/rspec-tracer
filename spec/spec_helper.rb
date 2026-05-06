# frozen_string_literal: true

# SimpleCov configuration — kept inline here (not in `.simplecov` at
# repo root) so the config does NOT leak into fixture subprocesses.
# SimpleCov's `.simplecov` auto-loader walks UPWARD from `Dir.pwd` to
# the filesystem root looking for the file (see
# simplecov/defaults.rb), and our integration / benchmark scenarios
# `chdir` into `spec/fixtures/rails_app` or `benchmark/fixtures/ruby_app`
# before booting the fixture. With `.simplecov` at the OUTER repo root
# the upward walk would find it from inside the fixture too, override
# the fixture's own minimal `SimpleCov.start { add_filter %r{/spec/} }`
# (the fixture guards `unless SimpleCov.running` and our auto-load
# already started it), enable branch coverage in the fixture process,
# and balloon SimpleCov's at_exit work — observed as a 3x regression
# on cold_rails_v2_warm_iter / cold_rails / cold_rails_v2 when
# `.simplecov` was committed at the repo root.
#
# Inline-in-spec_helper means this only fires when *our* spec_helper
# loads (`bundle exec rspec` from the repo root, drives our suite).
# Fixture subprocesses load their own spec_helper / rails_helper and
# never load this file.
require 'simplecov'

unless ENV['RSPEC_TRACER_DISABLE'] == '1' || ENV['COVERAGE'] == 'false' || defined?(Mutant)
  require 'simplecov_json_formatter'

  SimpleCov.formatters = [
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter
  ].freeze

  SimpleCov.start do
    enable_coverage :branch

    # Per-suite command_name. Without this, every `bundle exec rspec`
    # invocation REPLACES the prior "RSpec" entry — defeating the
    # multi-suite merge that `task coverage:merge` (and the CI
    # aggregator) depends on. Default 'unit' so a bare `bundle exec
    # rspec` still produces a recognizable entry.
    command_name(ENV.fetch('COVERAGE_SUITE', 'unit'))

    # Allow per-suite resultsets to live side-by-side for the
    # aggregator. Default merge_timeout is 600s; CI's slowest suite
    # chain can run past that, and locally a contributor may run
    # several `task test:*` tasks across a coffee break. 4 hours
    # covers both.
    use_merging true
    merge_timeout 14_400

    # Track every .rb file under lib/ so dead/unloaded code shows as
    # 0% rather than silently disappearing from the report.
    track_files 'lib/**/*.rb'

    # Tracker fixtures + sample apps + vendored bundles are NOT our
    # lib; exclude them from coverage attribution even when they get
    # loaded transitively (e.g. integration specs that boot the rails
    # fixture).
    add_filter '/spec/'
    add_filter '/benchmark/'
    add_filter '/vendor/'
    add_filter '/tmp/'
    add_filter '/coverage/'
    add_filter %r{/lib/rspec_tracer/reporters/html/}
    # Metadata-only file (single VERSION constant). Mirrors the
    # codecov.yml + scripts/merge_coverage.rb ignore lists.
    add_filter %r{/lib/rspec_tracer/version\.rb\z}
  end
end

require_relative 'support/tracker_coverage_gate'
TrackerCoverageGate.install!

require 'rspec_tracer'

# Skip the tracer self-instrumentation when running under mutant — the
# tracer's own Runner boot path calls TimeFormatter.format_time, and any
# mutation that makes that raise would prevent the spec_helper from
# loading at all, leaving mutant unable to distinguish "killed" from
# "setup crashed".
RSpecTracer.start unless ENV['RSPEC_TRACER_DISABLE'] == '1'

RSpec.configure do |config|
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
