# frozen_string_literal: true

# Single source of truth for SimpleCov configuration. Auto-loaded by
# `require 'simplecov'` (the lookup happens at require-time relative
# to Dir.pwd / SimpleCov.root). Per-suite differentiation comes via
# COVERAGE_SUITE env var so each `task test:*` invocation appends a
# distinct entry to coverage/.resultset.json instead of clobbering
# the previous one. The aggregator (scripts/merge_coverage.rb) then
# unions all per-suite resultsets across CI jobs into the canonical
# merged coverage report.
#
# Skipped under mutant — coverage collection during mutation runs is
# noisy (mutant runs targeted spec subsets per-mutation) and would
# contaminate the merged report. Same RSPEC_TRACER_DISABLE escape
# hatch the spec_helper uses for the engine itself.
return if defined?(Mutant)
return if ENV['RSPEC_TRACER_DISABLE'] == '1'
return if ENV['COVERAGE'] == 'false'

require 'simplecov_json_formatter'

SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::JSONFormatter
].freeze

SimpleCov.start do
  enable_coverage :branch

  # Per-suite command_name. Without this, every `bundle exec rspec`
  # invocation REPLACES the prior "RSpec" entry — defeating the
  # multi-suite merge. Default is 'unit' so a bare `bundle exec rspec`
  # still produces a recognizable entry.
  command_name(ENV.fetch('COVERAGE_SUITE', 'unit'))

  # Allow per-suite resultsets to live side-by-side for the aggregator.
  # Default merge_timeout is 600s; CI's slowest suite chain can run
  # past that, and locally a contributor may run several `task test:*`
  # tasks across a coffee break. 4 hours covers both.
  use_merging true
  merge_timeout 14_400

  # ---------- TRACK ----------
  # Track every .rb file under lib/ so dead/unloaded code shows as 0%
  # rather than silently disappearing from the report.
  track_files 'lib/**/*.rb'

  # ---------- FILTER ----------
  # Tracker fixtures + sample apps + vendored bundles are NOT our lib;
  # exclude them from coverage attribution even when they get loaded
  # transitively (e.g. integration specs that boot the rails fixture).
  add_filter '/spec/'                       # spec files themselves
  add_filter '/benchmark/'                  # benchmark scenarios + fixtures
  add_filter '/vendor/'                     # vendored bundles
  add_filter '/tmp/'                        # local scratch
  add_filter '/coverage/'                   # SimpleCov's own output
  add_filter %r{/lib/rspec_tracer/reporters/html/} # HTML reporter dist (vendored frontend)
end
