#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-backend cache-loader fuzz harness. Feeds random byte
# sequences into the files each storage backend reads, records
# the outcome distribution per backend. Complements the focused
# `json_backend_fuzz.rb` (which targets the :json serializer only)
# by exercising the OTHER decode pipelines:
#
#   - JsonBackend with serializer: :json   (already covered by
#     json_backend_fuzz.rb; included here for parity / regression
#     gate against the multi-backend dispatch).
#   - JsonBackend with serializer: :msgpack — zlib inflate +
#     MessagePack.unpack pipeline. Different parser, different
#     failure shapes.
#   - SqliteBackend — sqlite3 C bindings. A corrupted .sqlite3
#     file goes through SQLite's open + magic-byte check.
#
# All three backends are contracted to return nil + log on any
# corruption, never raise. Any iteration that produces something
# else (an unhandled exception class) shows up in the outcome
# distribution and fails CI.
#
# Usage:
#   ITERATIONS=300   bundle exec ruby spec/fuzz/cache_loader_fuzz.rb
#   ITERATIONS=10000 SEED=42 bundle exec ruby spec/fuzz/cache_loader_fuzz.rb
#
# Env:
#   ITERATIONS  total iterations across all backends (default 300;
#               distributed evenly per backend).
#   SEED        PRNG seed for reproducibility (default: fresh seed).
#   MAX_BYTES   upper bound on generated input size (default 4096).

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

iterations = Integer(ENV.fetch('ITERATIONS', '300'))
seed       = Integer(ENV.fetch('SEED', Random.new_seed.to_s))
max_bytes  = Integer(ENV.fetch('MAX_BYTES', '4096'))
rng        = Random.new(seed)

# Detect optional backends. SqliteBackend is MRI-only (sqlite3 gem
# targets MRI's C API; JRuby uses a different driver). Skip cleanly
# on missing-gem or JRuby cells.
sqlite_available =
  begin
    require 'sqlite3'
    require 'rspec_tracer/storage/sqlite_backend'
    RUBY_ENGINE == 'ruby'
  rescue LoadError
    false
  end

puts "cache_loader_fuzz iterations=#{iterations} seed=#{seed} max_bytes=#{max_bytes}"
puts "  sqlite_available=#{sqlite_available}"

# Build a minimal valid snapshot the backend can save before fuzz
# corruption begins. Same shape as
# spec/edge_cases/cache_corruption_spec.rb's helper.
def build_baseline_snapshot
  RSpecTracer::Storage::Snapshot.new(
    schema_version: RSpecTracer::Storage::Schema::CURRENT,
    run_id: 'fuzz-run',
    all_examples: { 'ex' => { id: 'ex', description: 'baseline' } },
    duplicate_examples: {},
    interrupted_examples: Set.new,
    flaky_examples: Set.new,
    failed_examples: Set.new,
    pending_examples: Set.new,
    skipped_examples: Set.new,
    all_files: { '/a.rb' => { file_name: '/a.rb', file_path: '/tmp/a.rb', digest: 'abc' } },
    dependency: { 'ex' => Set.new(['/a.rb']) },
    reverse_dependency: { '/a.rb' => Set.new(['ex']) },
    examples_coverage: { 'ex' => { '/a.rb' => [1] } },
    boot_set: {},
    wsi_snapshot: {},
    env_snapshot: {},
    env_dependency: {}
  )
end

# Run `iters` corruption iterations against `backend`. `targets` is
# the list of on-disk file paths the harness picks from per
# iteration; each pick gets random bytes overwritten, then
# load_graph runs + the outcome is bucketed.
CONTRACTED_OUTCOMES = %i[nil snapshot].freeze

# rubocop:disable Metrics/ParameterLists
def run_backend_fuzz(backend:, targets:, iters:, rng:, max_bytes:, restore_proc:)
  # rubocop:enable Metrics/ParameterLists
  outcomes = Hash.new(0)
  schema_version = RSpecTracer::Storage::Schema::CURRENT

  iters.times do
    target = targets.sample(random: rng)
    if File.file?(target)
      length = rng.rand(1..max_bytes)
      File.binwrite(target, rng.bytes(length))
    end

    begin
      result = backend.load_graph(schema_version: schema_version)
      outcomes[result.nil? ? :nil : :snapshot] += 1
    rescue SystemExit, Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      outcomes[e.class.name] += 1
    end

    restore_proc.call
  end

  outcomes
end

per_backend = sqlite_available ? (iterations / 3.0).ceil : (iterations / 2.0).ceil
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
all_outcomes = {}

# 1. JsonBackend :json
Dir.mktmpdir('rspec_tracer_fuzz_json_') do |cache_path|
  backend = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :json)
  baseline = build_baseline_snapshot
  backend.save_graph(baseline, schema_version: RSpecTracer::Storage::Schema::CURRENT)

  manifest = File.join(cache_path, RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME)
  per_field = RSpecTracer::Storage::JsonBackend::FIELD_NAMES.map { |f| File.join(cache_path, baseline.run_id, "#{f}.json") }
  targets = [manifest] + per_field

  restore = lambda do
    File.write(manifest,
               JSON.pretty_generate({ 'schema_version' => baseline.schema_version, 'run_id' => baseline.run_id,
                                      'timestamp' => Time.now.utc.iso8601 }))
    per_field.each { |p| File.write(p, '{}') }
  end

  outcomes = run_backend_fuzz(backend: backend, targets: targets, iters: per_backend,
                              rng: rng, max_bytes: max_bytes, restore_proc: restore)
  all_outcomes['JsonBackend :json'] = outcomes
end

# 2. JsonBackend :msgpack
Dir.mktmpdir('rspec_tracer_fuzz_msgpack_') do |cache_path|
  backend = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack)
  baseline = build_baseline_snapshot
  backend.save_graph(baseline, schema_version: RSpecTracer::Storage::Schema::CURRENT)

  manifest = File.join(cache_path, RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME)
  per_field = RSpecTracer::Storage::JsonBackend::FIELD_NAMES.map { |f| File.join(cache_path, baseline.run_id, "#{f}.msgpack.gz") }
  targets = [manifest] + per_field

  # Restoring the per-field files to a freshly-encoded msgpack-empty
  # state is awkward; simpler to re-save the baseline. Cheaper than
  # caching a known-good payload because save_graph is amortized
  # against many fuzz iterations.
  restore = lambda do
    File.write(manifest,
               JSON.pretty_generate({ 'schema_version' => baseline.schema_version, 'run_id' => baseline.run_id,
                                      'timestamp' => Time.now.utc.iso8601 }))
    backend.save_graph(baseline, schema_version: RSpecTracer::Storage::Schema::CURRENT) if rng.rand(50).zero?
  end

  outcomes = run_backend_fuzz(backend: backend, targets: targets, iters: per_backend,
                              rng: rng, max_bytes: max_bytes, restore_proc: restore)
  all_outcomes['JsonBackend :msgpack'] = outcomes
end

# 3. SqliteBackend (skip on JRuby / missing gem)
if sqlite_available
  Dir.mktmpdir('rspec_tracer_fuzz_sqlite_') do |cache_path|
    backend = RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path)
    baseline = build_baseline_snapshot
    backend.save_graph(baseline, schema_version: RSpecTracer::Storage::Schema::CURRENT)

    db_path = File.join(cache_path, RSpecTracer::Storage::SqliteBackend::DB_FILENAME)
    targets = [db_path]

    # SqliteBackend's only on-disk file is the .sqlite3. Restore by
    # re-saving the baseline (cheap; ~10ms per save).
    restore = lambda do
      backend.save_graph(baseline, schema_version: RSpecTracer::Storage::Schema::CURRENT) if rng.rand(20).zero?
    end

    outcomes = run_backend_fuzz(backend: backend, targets: targets, iters: per_backend,
                                rng: rng, max_bytes: max_bytes, restore_proc: restore)
    all_outcomes['SqliteBackend'] = outcomes
  end
else
  puts '  SqliteBackend: SKIPPED (sqlite3 gem unavailable on this Ruby)'
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts
total_iters = all_outcomes.values.sum { |outcomes| outcomes.values.sum }
puts "Results (~#{per_backend} iterations per backend, total #{total_iters} in #{format('%<secs>.2f',
                                                                                        secs: elapsed)}s):"
all_outcomes.each do |label, outcomes|
  total = outcomes.values.sum
  puts "\n[#{label}] #{total} iterations:"
  outcomes.sort_by { |k, _| k.to_s }.each do |klass, count|
    pct = total.zero? ? 0 : (count * 100.0 / total)
    printf("  %<klass>-50s %<count>6d  (%<pct>5.1f%%)\n", klass: klass, count: count, pct: pct)
  end
end
puts
puts "Reproduce with: SEED=#{seed} ITERATIONS=#{iterations} bundle exec ruby spec/fuzz/cache_loader_fuzz.rb"

# Fail the harness if any backend produced an exception class
# outside the contracted nil-or-snapshot return.
exception_outcomes = all_outcomes.values.flat_map(&:keys).reject { |k| CONTRACTED_OUTCOMES.include?(k) }
exit 1 if exception_outcomes.any?
