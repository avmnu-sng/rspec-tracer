#!/usr/bin/env ruby
# frozen_string_literal: true

# Fuzz harness for the v2 cache-loader path. Feeds random byte sequences
# into the files that `Storage::JsonBackend#load_graph` reads (the
# `last_run.json` manifest + every `FILENAMES` entry under the run-id
# directory) and records the outcome per iteration.
#
# `load_graph` is contracted to rescue StandardError and return nil on
# any corruption - fuzz verifies that contract holds under arbitrary
# byte inputs. Any escape that isn't the expected nil / Snapshot pair
# is a failure mode worth investigating.
#
# Replaces the pre-M5.1 `cache_loader_fuzz.rb` which targeted
# `RSpecTracer::Cache#load_all_examples_cache` (retired with the
# legacy reporter stack in M6.2).
#
# Usage:
#   ITERATIONS=100   bundle exec ruby spec/fuzz/json_backend_fuzz.rb
#   ITERATIONS=10000 SEED=42 bundle exec ruby spec/fuzz/json_backend_fuzz.rb
#
# Env:
#   ITERATIONS   how many random inputs to try (default 100)
#   SEED         PRNG seed for reproducibility (default: fresh seed)
#   MAX_BYTES    upper bound on generated input size (default 4096)

require 'json'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'rspec_tracer/storage/json_backend'

iterations = Integer(ENV.fetch('ITERATIONS', '100'))
seed       = Integer(ENV.fetch('SEED', Random.new_seed.to_s))
max_bytes  = Integer(ENV.fetch('MAX_BYTES', '4096'))
rng        = Random.new(seed)

outcomes = Hash.new(0)
started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

puts "json_backend_fuzz iterations=#{iterations} seed=#{seed} max_bytes=#{max_bytes}"

# Universe of target files - the manifest plus every per-run file the
# backend attempts to read. Each iteration picks one at random, writes
# garbage, and calls load_graph.
FILENAMES = RSpecTracer::Storage::JsonBackend::FILENAMES
MANIFEST  = RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME

Dir.mktmpdir('rspec_tracer_fuzz_') do |cache_path|
  backend = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
  run_id = 'fuzzrun'
  run_dir = File.join(cache_path, run_id)
  FileUtils.mkdir_p(run_dir)

  # Reasonable-manifest baseline; iterations either corrupt it or
  # corrupt one of the per-run JSON files under run_dir.
  manifest = { 'schema_version' => 3, 'run_id' => run_id, 'timestamp' => Time.now.utc.iso8601 }
  File.write(File.join(cache_path, MANIFEST), JSON.pretty_generate(manifest))
  FILENAMES.each do |name|
    next if name == MANIFEST

    File.write(File.join(run_dir, name), '{}')
  end

  iterations.times do
    # 50/50: corrupt the manifest or a random per-run file.
    target =
      if rng.rand(2).zero?
        File.join(cache_path, MANIFEST)
      else
        File.join(run_dir, FILENAMES.reject { |n| n == MANIFEST }.sample(random: rng))
      end

    length = rng.rand(1..max_bytes)
    File.binwrite(target, rng.bytes(length))

    begin
      result = backend.load_graph(schema_version: 3)
      outcomes[result.nil? ? :nil : :snapshot] += 1
    rescue SystemExit, Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      outcomes[e.class.name] += 1
    end

    # Restore the corrupted file to a plausible baseline for the next
    # iteration so every iteration starts from a partially-valid state.
    if target.end_with?(MANIFEST)
      File.write(target, JSON.pretty_generate(manifest))
    else
      File.write(target, '{}')
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
puts "Reproduce with: SEED=#{seed} ITERATIONS=#{iterations} bundle exec ruby spec/fuzz/json_backend_fuzz.rb"
