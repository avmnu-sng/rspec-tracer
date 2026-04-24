# frozen_string_literal: true

# Microbenchmark for storage backend load_graph paths.
#
# Builds a representative 500-example cache under tmpdir (example
# ids as MD5-hex strings, ~50 distinct file paths, modest
# per-example coverage map) and times load_graph + a touch of each
# returned field so the lazy reader materializes every payload.
#
# ENV knobs:
#   ITERATIONS   = outer load_graph repetitions (default 20)
#   EXAMPLES     = number of examples to populate (default 500)
#   FILES        = number of distinct file paths (default 50)
#   DEPS_PER_EX  = dependency fan-out per example (default 20)
#   BACKEND      = 'json' | 'sqlite' (default 'json')
#   SERIALIZER   = 'json' | 'msgpack' (JsonBackend only; default 'json')
#
# Emits one warn-level line with total + per-iteration wall time
# plus the on-disk size of the populated cache - the msgpack vs
# json delta is the disk-reduction claim a spec asserts separately.
# Subprocess wall time (captured by benchmark/harness.rb) covers
# Ruby boot + populate + N loads; the per-iteration line reported
# here isolates the load_graph cost for readers.

require 'fileutils'
require 'tmpdir'
require 'digest'
require 'set'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/schema'
require 'rspec_tracer/storage/snapshot'

ITERATIONS  = Integer(ENV.fetch('ITERATIONS', '20'))
EXAMPLES    = Integer(ENV.fetch('EXAMPLES', '500'))
FILES       = Integer(ENV.fetch('FILES', '50'))
DEPS_PER_EX = Integer(ENV.fetch('DEPS_PER_EX', '20'))
BACKEND     = ENV.fetch('BACKEND', 'json').to_sym
SERIALIZER  = ENV.fetch('SERIALIZER', 'json').to_sym

require 'rspec_tracer/storage/sqlite_backend' if BACKEND == :sqlite

# rubocop:disable Metrics/MethodLength, Metrics/AbcSize
def build_snapshot(examples:, files:, deps_per_ex:)
  example_ids = Array.new(examples) { |i| Digest::MD5.hexdigest("ex#{i}") }
  file_names  = Array.new(files)    { |i| "/app/models/file_#{i}.rb" }

  all_examples = example_ids.to_h do |id|
    [id, { id: id, description: "example #{id[0..7]}", file_name: file_names.first,
           line_number: 1, rerun_file_name: file_names.first, rerun_line_number: 1,
           full_description: "Example #{id}", example_group: 'Bench', shared_group: [] }]
  end
  all_files = file_names.to_h do |f|
    [f, { file_name: f, file_path: "/tmp#{f}", digest: Digest::MD5.hexdigest(f) }]
  end
  dependency = example_ids.to_h do |id|
    [id, Set.new(file_names.sample(deps_per_ex))]
  end
  reverse = Hash.new { |h, k| h[k] = Set.new }
  dependency.each { |id, paths| paths.each { |p| reverse[p] << id } }

  RSpecTracer::Storage::Snapshot.new(
    schema_version: RSpecTracer::Storage::Schema::CURRENT,
    run_id: Digest::MD5.hexdigest(example_ids.join),
    all_examples: all_examples,
    duplicate_examples: {},
    interrupted_examples: Set.new, flaky_examples: Set.new,
    failed_examples: Set.new, pending_examples: Set.new, skipped_examples: Set.new,
    all_files: all_files,
    dependency: dependency,
    reverse_dependency: reverse,
    examples_coverage: example_ids.first(100).to_h { |id| [id, { file_names.first => { '1' => 1 } }] },
    boot_set: { 'lib/boot.rb' => 'deadbeef' },
    wsi_snapshot: { 'Gemfile.lock' => 'feedc0de' },
    env_snapshot: {},
    env_dependency: {}
  )
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize

def build_backend(cache_path)
  case BACKEND
  when :sqlite
    RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path)
  else
    RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: SERIALIZER)
  end
end

def cache_size_bytes(cache_path)
  Dir.glob(File.join(cache_path, '**', '*')).sum do |p|
    File.file?(p) ? File.size(p) : 0
  end
end

cache_path = Dir.mktmpdir('cache_load_bench')
begin
  srand(42) # deterministic dependency.sample across runs
  snapshot = build_snapshot(examples: EXAMPLES, files: FILES, deps_per_ex: DEPS_PER_EX)

  build_backend(cache_path)
    .save_graph(snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
  disk_bytes = cache_size_bytes(cache_path)

  # Warm once (pays first-load JIT + require tax outside the timed loop).
  build_backend(cache_path)
    .load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
    .to_h

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ITERATIONS.times do
    loaded = build_backend(cache_path)
      .load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
    # Touch every field so the lazy reader materializes; mirrors
    # Engine.setup's access pattern.
    loaded.to_h
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  warn format(
    'cache_load: backend=%<b>s serializer=%<s>s %<i>d iters x %<e>d examples x %<f>d files x %<d>d deps/ex, ' \
    'disk=%<kb>dKB elapsed=%<el>.3fs (per-iter=%<pi>.3fms)',
    b: BACKEND, s: SERIALIZER, i: ITERATIONS, e: EXAMPLES, f: FILES, d: DEPS_PER_EX,
    kb: disk_bytes / 1024, el: elapsed, pi: elapsed * 1000.0 / ITERATIONS
  )
ensure
  FileUtils.remove_entry(cache_path)
end
