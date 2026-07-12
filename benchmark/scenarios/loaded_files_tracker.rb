# frozen_string_literal: true

# Microbenchmark for RSpecTracer::Tracker::LoadedFilesTracker#stop_example.
#
# Contract: `stop_example` overhead stays <= 1 ms per example including
# loaded-files attribution.
#
# Scenarios measured, all against an in-root fixture of FILE_COUNT Ruby
# files so File.file? + SHA256 on new paths is paid in cents-per-call:
#
#   baseline_steady: stop_example when peek already matches @loaded_set
#                    (no new paths, no digest work). Represents the
#                    typical post-warmup case - a large project with
#                    all files pre-loaded.
#   growing:         stop_example when each iteration exposes one new
#                    path (full work: filter, digest, Input.for_file,
#                    Set.merge). Represents early-run behavior when
#                    lazy requires are still firing.
#
# Invoked as a scenario inside benchmark/harness.rb. The harness times
# the whole subprocess wall-clock; the inner loops report per-call
# microsecond overhead to stderr for the PR summary.
#
#   BOOT_FILES=500 STEADY_ITERS=10000 GROWING_ITERS=2000 \
#     bundle exec ruby benchmark/scenarios/loaded_files_tracker.rb

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'rspec_tracer/tracker/loaded_files_tracker'

BOOT_FILES = Integer(ENV.fetch('BOOT_FILES', '500'))
STEADY_ITERS = Integer(ENV.fetch('STEADY_ITERS', '10_000'))
GROWING_ITERS = Integer(ENV.fetch('GROWING_ITERS', '2_000'))
STEADY_MAX_US = Float(ENV.fetch('STEADY_MAX_US', '1000.0'))

root = Dir.mktmpdir('loaded_files_bench')
begin
  boot_paths = Array.new(BOOT_FILES) do |i|
    p = File.join(root, "lib/boot/f#{i}.rb")
    FileUtils.mkdir_p(File.dirname(p))
    File.write(p, "module F#{i}\n  VALUE = #{i}\nend\n")
    p
  end

  growing_paths = Array.new(GROWING_ITERS) do |i|
    p = File.join(root, "lib/lazy/f#{i}.rb")
    FileUtils.mkdir_p(File.dirname(p))
    File.write(p, "module Lazy#{i}\n  VALUE = #{i}\nend\n")
    p
  end

  # Steady-state: peek always returns the same set, @loaded_set is
  # primed with the same set, diff is empty every call. Measures the
  # hot-path cost (Set subtraction of big-but-identical sets).
  steady_tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
    root: root, peek: -> { boot_paths }
  )
  steady_tracker.capture_boot_set!

  steady_tracker.stop_example('warm') # warm

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  STEADY_ITERS.times { |i| steady_tracker.stop_example("ex#{i}") }
  steady_total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  steady_per_call_us = steady_total * 1e6 / STEADY_ITERS

  # Growing: each call exposes one new file, so digest + Input.for_file
  # + @loaded_set.merge fire each iteration. Measures the
  # worst-realistic per-call cost.
  growing_peek_cursor = 0
  growing_peek = lambda do
    boot_paths + growing_paths[0...growing_peek_cursor]
  end
  growing_tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
    root: root, peek: growing_peek
  )
  growing_tracker.capture_boot_set!

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GROWING_ITERS.times do |i|
    growing_peek_cursor = i + 1
    growing_tracker.stop_example("ex#{i}")
  end
  growing_total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  growing_per_call_us = growing_total * 1e6 / GROWING_ITERS

  warn format(
    'loaded_files_tracker: boot=%<b>d steady=%<sus>.2fus/call (N=%<sn>d) ' \
    'growing=%<gus>.2fus/call (N=%<gn>d)',
    b: BOOT_FILES,
    sus: steady_per_call_us, sn: STEADY_ITERS,
    gus: growing_per_call_us, gn: GROWING_ITERS
  )

  # AC-internal gate on the steady-state cost. Growing-state cost is
  # informational (depends on fixture size + filesystem speed + CPU).
  if steady_per_call_us > STEADY_MAX_US
    warn format(
      'FAIL: steady-state stop_example overhead %<us>.2fus exceeds %<max>.0fus ceiling',
      us: steady_per_call_us, max: STEADY_MAX_US
    )
    exit 1
  end
ensure
  FileUtils.remove_entry(root)
end
