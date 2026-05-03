# frozen_string_literal: true

# Long-running benchmark scenario for `cold_rails_v2_warm_iter`.
#
# Runs INSIDE the rails_app fixture's bundler context. Boots Rails
# ONCE at the top of this script; then per iteration `Process.fork`s
# a child that runs the spec/ via `RSpec::Core::Runner`. Wall-clock
# is measured around the fork+wait pair, so per-iter measurement
# excludes the cold Rails-boot cost (which is amortized across
# iterations in the parent).
#
# Stdout shape (one JSON line per iter, plus a trailing summary):
#
#   {"iter":1,"timing":2.314}
#   {"iter":2,"timing":2.276}
#   ...
#   {"summary":{"timings":[...],"p50":...,"p95":...}}
#
# Used by `BenchmarkHarness::SCENARIOS['cold_rails_v2_warm_iter']`.
# The harness invokes this script ONCE and aggregates the per-iter
# JSON lines (instead of doing N Open3 calls and timing each
# separately).
#
# State reset between iterations:
#   - rspec_tracer cache + report + coverage dirs wiped before each
#     iter so the cache is cold (consistent with cold_rails_v2's
#     measurement intent).
#   - Each fork() child gets a fresh process, so RSpec.world /
#     ::Coverage / RSpecTracer engine state are pristine on entry.
#     The parent's pre-loaded Rails constants / autoload paths are
#     inherited (no re-load cost).
#
# Why fork() instead of exec()? exec() would re-execve into a fresh
# Ruby process and require Rails from scratch (defeats the point).
# fork() inherits the parent's loaded Rails/AR/etc., so the child
# starts with the autoload index already warm.

require 'benchmark'
require 'fileutils'
require 'json'

ITERATIONS = (ENV['BENCH_ITERATIONS'] || '5').to_i

# Script is invoked via `bundle exec ruby` from the fixture cwd
# (see harness.rb's SCENARIOS['cold_rails_v2_warm_iter']). Pin the
# fixture path off the current working directory so we don't depend
# on __FILE__ resolution (which varies between Rubies + load
# methods).
FIXTURE_PATH = Dir.pwd

# Boot Rails ONCE in the parent (cost amortized across iters).
# Child processes inherit this state via fork().
ENV['RAILS_ENV'] ||= 'test'
require 'bundler/setup'
require File.join(FIXTURE_PATH, 'config', 'environment')

CLEAN_DIRS = %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage coverage].freeze

def cleanup_iter_state
  CLEAN_DIRS.each { |d| FileUtils.rm_rf(File.join(FIXTURE_PATH, d)) }
end

def median(values)
  sorted = values.sort
  n = sorted.length
  return 0.0 if n.zero?

  n.odd? ? sorted[n / 2] : (sorted[(n / 2) - 1] + sorted[n / 2]) / 2.0
end

def percentile(values, pct)
  return 0.0 if values.empty?

  sorted = values.sort
  k = ((pct / 100.0) * (sorted.length - 1)).ceil
  sorted[k]
end

# Per-iter: fork a child that runs rspec; parent waits + measures.
# Child loads RSpecTracer + the spec_helper + RSpec::Core::Runner
# inside its own process so Coverage / RSpec.world state is pristine.
timings = []
ITERATIONS.times do |i|
  cleanup_iter_state

  elapsed = Benchmark.realtime do
    pid = Process.fork do
      # Child inherits parent's Rails/AR autoload state. RSpec +
      # rspec-tracer load fresh in the child (so Coverage hooks
      # install cleanly).
      Dir.chdir(FIXTURE_PATH) do
        $LOAD_PATH.unshift(File.join(FIXTURE_PATH, 'spec'))
        require 'rspec_tracer'
        RSpecTracer.start
        require 'rspec/core'
        RSpec::Core::Runner.run(['spec'])
      end
    end
    Process.wait(pid)
  end

  timings << elapsed
  $stdout.puts(JSON.generate(iter: i + 1, timing: elapsed.round(4)))
  $stdout.flush
end

summary = {
  timings: timings.map { |t| t.round(4) },
  p50: median(timings).round(4),
  p95: percentile(timings, 95).round(4)
}
$stdout.puts(JSON.generate(summary: summary))
