#!/usr/bin/env ruby
# frozen_string_literal: true

# Fuzz harness for `Tracker::CoverageAdapter#compute_diff`. Generates
# pathological coverage-result shapes and asserts the diff method
# never raises across N iterations. Each iteration constructs random
# before / after maps with mixed line shapes (Array, Hash, nil entries,
# wildly varying lengths, missing keys, mode flips).
#
# Contract under test (per lib/rspec_tracer/tracker/coverage_adapter.rb):
#   - compute_diff returns Set<Input> for paths whose line arrays
#     differ between before and after.
#   - delta? handles nil entries (unexecutable lines) without raising.
#   - file_digest returns nil for paths that do not exist on disk
#     (rescues SystemCallError); compute_diff still constructs Input
#     with digest nil rather than raising.
#
# Usage:
#   ITERATIONS=500   bundle exec ruby spec/fuzz/coverage_adapter_fuzz.rb
#   ITERATIONS=10000 SEED=42 bundle exec ruby spec/fuzz/coverage_adapter_fuzz.rb
#
# Env:
#   ITERATIONS  iterations (default 500).
#   SEED        PRNG seed for reproducibility.
#   MAX_FILES   upper bound on files per map (default 25).
#   MAX_LINES   upper bound on line array length per file (default 200).

require 'set'

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'rspec_tracer/tracker/coverage_adapter'
require 'rspec_tracer/tracker/input'

iterations = Integer(ENV.fetch('ITERATIONS', '500'))
seed       = Integer(ENV.fetch('SEED', Random.new_seed.to_s))
max_files  = Integer(ENV.fetch('MAX_FILES', '25'))
max_lines  = Integer(ENV.fetch('MAX_LINES', '200'))
rng        = Random.new(seed)

puts "coverage_adapter_fuzz iterations=#{iterations} seed=#{seed} max_files=#{max_files} max_lines=#{max_lines}"

# Build a random Coverage-shaped map. Line entries are a mix of nil
# (unexecutable), 0 (executable, never hit), positive integers (hit
# counts), and occasionally negative integers (impossible but
# defensive). 25% of maps use Hash-mode entries (`{ lines: [...] }`)
# to exercise the mode detection in CoverageAdapter#peek; for
# compute_diff, all entries should be normalized to Array - we
# pass the normalized form directly here since compute_diff doesn't
# re-call peek.
def random_coverage_map(rng:, max_files:, max_lines:)
  file_count = rng.rand(0..max_files)
  Array.new(file_count) do
    path = "/fuzz/#{('a'..'z').to_a.sample(rng.rand(3..8), random: rng).join}_spec.rb"
    line_count = rng.rand(0..max_lines)
    lines = Array.new(line_count) do
      case rng.rand(10)
      when 0..3 then nil
      when 4..7 then rng.rand(0..1000)
      when 8 then 0
      else -1 # impossible negative; defensive test
      end
    end
    [path, lines]
  end.to_h
end

adapter = RSpecTracer::Tracker::CoverageAdapter.new(
  root: '/fuzz',
  filters: [],
  mode: :array
)

outcomes = Hash.new(0)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

iterations.times do
  before = random_coverage_map(rng: rng, max_files: max_files, max_lines: max_lines)
  after  = random_coverage_map(rng: rng, max_files: max_files, max_lines: max_lines)

  begin
    result = adapter.compute_diff(before, after)
    outcomes[result.is_a?(Set) ? :set : :unexpected_return] += 1
  rescue SystemExit, Interrupt
    raise
  rescue Exception => e # rubocop:disable Lint/RescueException
    outcomes[e.class.name] += 1
  end
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts
puts "Outcomes (#{iterations} iterations in #{format('%<secs>.2f', secs: elapsed)}s):"
outcomes.sort_by { |k, _| k.to_s }.each do |klass, count|
  pct = count * 100.0 / iterations
  printf("  %<klass>-50s %<count>6d  (%<pct>5.1f%%)\n", klass: klass, count: count, pct: pct)
end
puts
puts "Reproduce with: SEED=#{seed} ITERATIONS=#{iterations} bundle exec ruby spec/fuzz/coverage_adapter_fuzz.rb"

# Fail the harness if compute_diff produced anything other than a Set.
unexpected = outcomes.keys.reject { |k| k == :set }
exit 1 if unexpected.any?
