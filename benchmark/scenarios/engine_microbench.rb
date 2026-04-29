# frozen_string_literal: true

# Microbenchmark for the per-example engine hot loop:
# Engine#example_started + #example_finished, exercising
# Tracker::CoverageAdapter#peek_normalized + IOHooks._record +
# LoadedFilesTracker#stop_example end-to-end against a synthetic
# project. Drives the same code paths as a real cold_rails run but
# in a single Ruby process so stackprof can attach.
#
# ENV knobs:
#   ENGINE_ITERS  = number of synthetic example cycles (default 2_000)
#   ENGINE_FILES  = synthetic lib files to read inside each example
#                    (default 5; per-example File.read fan-out)

require 'coverage'
Coverage.start unless Coverage.respond_to?(:running?) && Coverage.running?

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'rspec_tracer'

ENGINE_ITERS = Integer(ENV.fetch('ENGINE_ITERS', '2_000'))
ENGINE_FILES = Integer(ENV.fetch('ENGINE_FILES', '5'))

project_root = Dir.mktmpdir('engine_microbench_')
begin
  FileUtils.mkdir_p(File.join(project_root, 'lib'))
  sample_paths = Array.new(ENGINE_FILES) do |i|
    p = File.join(project_root, "lib/sample_#{i}.rb")
    File.write(p, "module Sample#{i}\n  VALUE = #{i}\nend\n")
    p
  end

  # Set root via the public Configuration DSL (already aliased by
  # load_config's require chain at gem-load time). Bypass
  # `RSpecTracer.configure { ... }` because its caller-path gate only
  # accepts the three load_*_config.rb loaders. cache_path derives
  # from root + DEFAULT_CACHE_DIR; no explicit setter needed.
  RSpecTracer.root(project_root)

  engine = RSpecTracer::Engine.new(configuration: RSpecTracer)
  engine.setup

  ENGINE_ITERS.times do |i|
    example_id = format('synthetic-%05d', i)
    engine.register_example(
      example_id: example_id,
      description: 'engine microbench',
      full_description: "engine microbench #{i}",
      example_group: 'EngineMicrobench',
      file_name: '/synthetic_spec.rb',
      file_path: File.join(project_root, 'synthetic_spec.rb'),
      line_number: 1,
      rerun_file_name: '/synthetic_spec.rb',
      rerun_line_number: 1
    )
    engine.example_started
    sample_paths.each { |path| File.read(path) }
    engine.example_finished(example_id)
  end

  # Don't call finalize — we want the profile to focus on the
  # per-example hot loop, not the one-time graph save. A separate
  # profile:cache_load scenario covers save_graph / load_graph.
  warn format(
    'engine_microbench: %<i>d iters x %<f>d files/example',
    i: ENGINE_ITERS, f: ENGINE_FILES
  )
ensure
  FileUtils.remove_entry(project_root)
end
