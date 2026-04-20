#!/usr/bin/env ruby
# frozen_string_literal: true

# Fuzz harness for the cache-loader path. Feeds random byte sequences into
# `Cache#load_all_examples_cache` and records what each input raised (or
# didn't). The harness itself must never crash; it's the observer, not the
# subject.
#
# Usage:
#   ITERATIONS=100  bundle exec ruby spec/fuzz/cache_loader_fuzz.rb
#   ITERATIONS=10000 SEED=42 bundle exec ruby spec/fuzz/cache_loader_fuzz.rb
#
# Env:
#   ITERATIONS   how many random inputs to try (default 100)
#   SEED         PRNG seed for reproducibility (default: fresh seed)
#   MAX_BYTES    upper bound on generated input size (default 4096)

require 'json'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'rspec_tracer/cache'

iterations = Integer(ENV.fetch('ITERATIONS', '100'))
seed       = Integer(ENV.fetch('SEED', Random.new_seed.to_s))
max_bytes  = Integer(ENV.fetch('MAX_BYTES', '4096'))
rng        = Random.new(seed)

outcomes = Hash.new(0)
started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

puts "cache_loader_fuzz iterations=#{iterations} seed=#{seed} max_bytes=#{max_bytes}"

Dir.mktmpdir('rspec_tracer_fuzz_') do |dir|
  target = File.join(dir, 'all_examples.json')

  iterations.times do
    length = rng.rand(1..max_bytes)
    File.binwrite(target, rng.bytes(length))

    begin
      RSpecTracer::Cache.new.send(:load_all_examples_cache, dir)
      outcomes[:ok] += 1
    rescue SystemExit, Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      outcomes[e.class.name] += 1
    end
  end
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts "\nOutcomes (#{iterations} iterations in #{format('%<secs>.2f', secs: elapsed)}s):"
outcomes.sort_by { |k, _| k.to_s }.each do |klass, count|
  pct = count * 100.0 / iterations
  printf("  %<klass>-40s %<count>6d  (%<pct>5.1f%%)\n", klass: klass, count: count, pct: pct)
end
puts
puts "Reproduce with: SEED=#{seed} ITERATIONS=#{iterations} bundle exec ruby spec/fuzz/cache_loader_fuzz.rb"
