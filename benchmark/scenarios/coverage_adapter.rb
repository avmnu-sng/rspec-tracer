# frozen_string_literal: true

# Microbenchmark for RSpecTracer::Tracker::CoverageAdapter#compute_diff.
#
# Builds synthetic ::Coverage-shaped before/after hashes across 100
# files (each LINES_PER_FILE lines, with one deterministic line-count
# delta per file), then calls compute_diff ITERATIONS times.
#
# Invoked as a scenario inside benchmark/harness.rb. The harness times
# the whole subprocess wall-clock; dividing by ITERATIONS gives a
# per-call cost on the measurement host.
#
#   ITERATIONS=1000 bundle exec ruby benchmark/scenarios/coverage_adapter.rb

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'rspec_tracer/tracker/coverage_adapter'

ITERATIONS = Integer(ENV.fetch('ITERATIONS', '1000'))
FILE_COUNT = Integer(ENV.fetch('FILE_COUNT', '100'))
LINES_PER_FILE = Integer(ENV.fetch('LINES_PER_FILE', '50'))

root = Dir.mktmpdir('coverage_adapter_bench')
begin
  paths = Array.new(FILE_COUNT) do |i|
    p = File.join(root, "f#{i}.rb")
    File.write(p, "puts #{i}\n" * LINES_PER_FILE)
    p
  end

  zeros = Array.new(LINES_PER_FILE, 0).freeze
  ones_first = ([1] + Array.new(LINES_PER_FILE - 1, 0)).freeze
  before = paths.to_h { |p| [p, zeros] }
  after = paths.to_h { |p| [p, ones_first] }

  adapter = RSpecTracer::Tracker::CoverageAdapter.new(root: root)
  # Warm once — pays the first-time require/JIT tax outside the timed loop.
  adapter.compute_diff(before, after)

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ITERATIONS.times { adapter.compute_diff(before, after) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  warn format(
    'coverage_adapter: %<i>d iters × %<f>d files × %<l>d lines, ' \
    'elapsed=%<e>.3fs (per-iter=%<pi>.3fms)',
    i: ITERATIONS, f: FILE_COUNT, l: LINES_PER_FILE,
    e: elapsed, pi: elapsed * 1000.0 / ITERATIONS
  )
ensure
  FileUtils.remove_entry(root)
end
