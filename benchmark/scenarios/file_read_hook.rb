# frozen_string_literal: true

# Microbenchmark for RSpecTracer::Tracker::IOHooks#record fast-reject.
#
# Three measurements, all against a tiny in-root fixture so File.read
# itself is cheap (μs-scale). What we want to see is the *additional*
# overhead the hook adds on top of the native call.
#
#   baseline: hook uninstalled, just File.read in a tight loop.
#   reject:   hook installed but no bucket set (production path when
#             the tracer isn't mid-example) - records must fast-reject.
#   record:   hook installed + bucket set, each iteration reads a
#             distinct fixture (no dedup short-circuit, full SHA256
#             digest + Input construction paid per iter).
#
# Invoked as a scenario inside benchmark/harness.rb. The harness times
# the whole subprocess wall-clock; the inner loops report per-call
# nanosecond overhead to stderr for the PR summary.
#
#   REJECT_ITERS=100000 RECORD_ITERS=10000 bundle exec ruby benchmark/scenarios/file_read_hook.rb

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'rspec_tracer/tracker/io_hooks'

REJECT_ITERS = Integer(ENV.fetch('REJECT_ITERS', '100_000'))
RECORD_ITERS = Integer(ENV.fetch('RECORD_ITERS', '10_000'))

root = Dir.mktmpdir('io_hooks_bench')
begin
  fixture = File.join(root, 'fixture.yml')
  File.write(fixture, "k: v\n")

  # Distinct fixtures for the record path so dedup doesn't short-circuit.
  record_fixtures = Array.new(RECORD_ITERS) do |i|
    p = File.join(root, "f#{i}.yml")
    File.write(p, "k: #{i}\n")
    p
  end

  # Baseline: no hook installed.
  REJECT_ITERS.times { File.read(fixture) } # warm
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  REJECT_ITERS.times { File.read(fixture) }
  baseline = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  RSpecTracer::Tracker::IOHooks.install(root: root)

  # Reject path: hook installed, no bucket.
  REJECT_ITERS.times { File.read(fixture) } # warm
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  REJECT_ITERS.times { File.read(fixture) }
  reject_total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  reject_overhead_ns = (reject_total - baseline) * 1e9 / REJECT_ITERS

  # Record path: distinct fixtures, full work per call.
  bucket = {}
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  RSpecTracer::Tracker::IOHooks.with_bucket(bucket) do
    record_fixtures.each { |f| File.read(f) }
  end
  record_total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  record_per_call_us = record_total * 1e6 / RECORD_ITERS

  warn format(
    'io_hooks: baseline=%<b>.3fs reject_overhead=%<r>.0fns/call (N=%<rn>d) ' \
    'record_per_call=%<rc>.1fus (N=%<rcn>d, bucket=%<bs>d)',
    b: baseline,
    r: reject_overhead_ns, rn: REJECT_ITERS,
    rc: record_per_call_us, rcn: RECORD_ITERS, bs: bucket.size
  )
ensure
  FileUtils.remove_entry(root)
end
