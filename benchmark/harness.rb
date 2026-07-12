# frozen_string_literal: true

# rspec-tracer benchmark harness.
#
# Measures rspec-tracer overhead across 4 scenarios and compares
# against a committed ratchet file. Builds fail if any scenario's
# median time exceeds the ratchet's P50 by > REGRESSION_FAIL_RATIO
# (30% by default; 20% before per-PR enforcement on the
# GHA baseline surfaced empirical small-sample variance in the
# 1.20-1.22x band on microbenches). Warnings are emitted between
# REGRESSION_WARN_RATIO (10%) and REGRESSION_FAIL_RATIO.
#
# See benchmark/README.md for the update policy.
#
#   ruby benchmark/harness.rb --smoke
#   ruby benchmark/harness.rb --full --ratchet benchmark/ratchet.json
#   ruby benchmark/harness.rb --full --update-ratchet benchmark/ratchet.json --yes
#
# Each scenario runs N iterations (default 5), reports median + P95,
# emits one JSON-line result per scenario to stdout plus a human
# summary to stderr. Environment metadata (ruby, OS, CPU) is recorded
# per-run so ratchet adjustments can compare apples-to-apples.

require 'benchmark'
require 'etc'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'time'

# rubocop:disable Metrics/ModuleLength
module BenchmarkHarness
  REPO_ROOT = File.expand_path('..', __dir__)
  RUBY_FIXTURE = File.join(REPO_ROOT, 'benchmark/fixtures/ruby_app')
  RAILS_FIXTURE = File.join(REPO_ROOT, 'spec/fixtures/rails_app')

  REGRESSION_WARN_RATIO = 1.10
  # Bumped from 1.20 to 1.30 at the first per-PR GHA-gated run,
  # which landed coverage_adapter (1.21x) + loaded_files_tracker
  # (1.22x) over the prior 1.20 threshold purely from GHA shared-
  # runner small-sample variance (5 iters per scenario; p50 is
  # high-variance on microbenches at that sample size). GHA runners
  # shift non-uniformly per scenario vs the local baseline machine
  # (Rails-heavy scenarios 3-3.5x slower, pure-Ruby microbenches flat
  # or faster), so the 1.30 value came from the empirical WARN/FAIL
  # distribution of the regen baseline. Tightening back
  # toward 1.20 is a 2.x calibration once multiple GHA baselines
  # accumulate enough variance signal to set a defensible per-
  # scenario threshold; tracked as a 2.1 followup.
  REGRESSION_FAIL_RATIO = 1.30

  # Scenarios whose wall-clock variance exceeds the gate threshold
  # by structural property (worker-subprocess CPU contention on
  # shared runners) get reported but NOT gated. Their ratio is
  # printed as `INFO` and never contributes to exit-non-zero.
  #
  # Currently only `parallel_tests_2_workers` qualifies: the GHA-
  # baseline regen recorded p50=0.8665 / p95=1.8682 (p95/p50 = 2.16x)
  # within its own 10-iter sample - the baseline itself acknowledges
  # >2x variance, so any threshold below 2.16x will fail on noise
  # alone. Two structural causes compound:
  #
  #   1. Process contention: `parallel_rspec` spawns driver + 2
  #      workers = 3 Ruby processes on GHA's 2-vCPU runners. Worst-
  #      case wall = max(worker_wall) + merge overhead; on contended
  #      CPU each worker can be 2x of dedicated wall.
  #   2. Worker startup variance amplified by max-of-N: each worker
  #      boots Ruby + Bundler + gem set independently; the driver
  #      waits for the slowest to finish.
  #
  # The right regression signal for these scenarios would be a
  # behavior assertion (cache-merge correctness, no worker crash)
  # rather than wall-clock comparison. Wall-clock stays as
  # informational summary output for trend-watching but doesn't
  # gate. See benchmark/README.md "Informational scenarios" for
  # the user-facing rationale.
  INFORMATIONAL_SCENARIOS = %w[parallel_tests_2_workers].freeze

  DEFAULT_ITERATIONS_FULL = 5
  DEFAULT_ITERATIONS_SMOKE = 3

  STATUS_ICONS = { ok: '✓', warn: '⚠', fail: '✗', informational: 'ℹ' }.freeze

  # Per-interpreter ratchet multipliers. The committed ratchet.json is a
  # canonical MRI baseline (Apple M2 Max + Ruby 3.3.10). Non-MRI
  # interpreters run materially slower on these scenarios primarily
  # because each iteration spawns a fresh subprocess: JRuby pays full
  # JVM boot per-iter (~2.5s on its own, dominating cold_ruby's wall
  # clock); TruffleRuby pays Graal compile-time on the same cold path.
  # Multipliers below are calibrated to empirical reality on the
  # canonical M2 Max hardware - JRuby cold_ruby clocks ~2.81s vs MRI's
  # 0.29s (~9.7x raw), so 10.0 leaves margin for GHA ubuntu-latest's
  # additional ~1.4-1.6x scheduling jitter. TruffleRuby is best-effort
  # + continue-on-error in CI; 5.0 is a conservative starting point
  # pending first-cell empirical data.
  # Default 1.0x for any interpreter not listed (e.g. ruby head).
  # Non-MRI cells use task benchmark:smoke:no-enforce so threshold
  # miscalibration never blocks CI; the displayed ratio is informational.
  INTERPRETER_RATCHET_MULTIPLIERS = {
    'ruby' => 1.0,
    'jruby' => 10.0,
    'truffleruby' => 5.0
  }.freeze

  # Scenarios. Each is a Hash with:
  #   cwd:         working dir for the subprocess
  #   cmd:         Array passed to Open3.capture2e
  #   env:         ENV additions for the subprocess
  #   cleanup:     relative paths under cwd removed before each iteration
  #                (enforces cold state)
  #   warmup:      Proc run once before timing (e.g., populate cache first)
  #   smoke:       runs under --smoke mode
  SCENARIOS = {
    'cold_ruby' => {
      desc: 'Cold start: Ruby-only fixture, empty cache',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: {},
      cleanup: %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage],
      smoke: true
    },
    'warm_noop' => {
      desc: 'Warm run: same fixture, cache populated, no file changes',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: {},
      warmup: ->(cwd) { run_rspec_once(cwd, {}) },
      smoke: true
    },
    'warm_env_mismatch' => {
      # Per-example env-snapshot mismatch: warmup primes the cache with the
      # tracked env = 'baseline'; iterations run with the tracked env
      # flipped to 'changed', which forces the env-annotated describe
      # block (Calculator in calculator_spec.rb) through the env_changed
      # filter path. First iteration hits the re-run path; subsequent
      # iterations see env match the last cached value and fall back to
      # warm_noop. Scenario pinned to smoke:false so `task check`
      # stays under its fast-feedback budget.
      desc: 'Warm run with env_snapshot mismatch on the first iteration (env-tracking overhead floor)',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: { 'RSPEC_TRACER_BENCH_ENV' => 'changed' },
      warmup: ->(cwd) { run_rspec_once(cwd, { 'RSPEC_TRACER_BENCH_ENV' => 'baseline' }) },
      smoke: false
    },
    'track_env_warm_mismatch' => {
      # Config-level + wildcard env-snapshot mismatch. The fixture's
      # .rspec-tracer declares `track_env 'RSPEC_TRACER_BENCH_CONFIG_*'`
      # at config level. Warmup primes the cache with
      # RSPEC_TRACER_BENCH_CONFIG_KEY = 'baseline' (matched by the
      # wildcard at register_config_tracked_env_names time); iterations
      # run with the env flipped to 'changed', forcing every example
      # through the config-level env_changed path
      # (apply_env_filter_decisions's invalidated.intersect?(@config_*)
      # branch). Holds the steady-state config-level wildcard expansion
      # + global mark-every-example overhead on the ratchet so
      # regressions in that hot-path show up. smoke:false matches
      # warm_env_mismatch's shape (subprocess boot dominates 3-iter
      # variance against own ratchet).
      desc: 'Warm run with config-level wildcard env_snapshot mismatch on first iteration',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: { 'RSPEC_TRACER_BENCH_CONFIG_KEY' => 'changed' },
      warmup: ->(cwd) { run_rspec_once(cwd, { 'RSPEC_TRACER_BENCH_CONFIG_KEY' => 'baseline' }) },
      smoke: false
    },
    'parallel_tests_2_workers' => {
      desc: 'parallel_tests with 2 workers, cold: worker split + merge at exit',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec parallel_rspec spec],
      env: { 'PARALLEL_TEST_GROUPS' => '2' },
      cleanup: %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage rspec_tracer.lock],
      # smoke:false keeps `task check` under its fast-feedback budget -
      # parallel_tests startup is ~1.5s per iteration, dominates the smoke
      # wall clock. Runs on benchmark:full and CI.
      smoke: false
    },
    'cold_rails' => {
      desc: 'Cold start: Rails fixture, empty cache (narrow scope: spec/models only)',
      cwd: RAILS_FIXTURE,
      cmd: %w[bundle exec rspec --no-color spec/models],
      env: {
        'RAILS_VERSION' => '~> 7.1.0',
        'RSPEC_RAILS_VERSION' => '~> 6.1.0',
        'SQLITE3_VERSION' => '~> 1.4',
        'RSPEC_TRACER' => '1'
      },
      cleanup: %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage coverage],
      setup: lambda do |cwd|
        system('bundle', 'exec', 'rails', 'db:test:prepare',
               chdir: cwd, out: File::NULL, err: File::NULL)
      end,
      smoke: false
    },
    'cold_rails_v2' => {
      # Broader Rails fixture cold-start (full spec/ tree). Eager-loads
      # ~300+ initializer files through the coverage stack; before the
      # legacy-reporter retirement this exercised both the legacy
      # CoverageReporter peek+diff per example AND the Engine peek+diff. Post-retirement only Engine
      # peeks. The wall-clock delta on this scenario is the largest
      # single signal for the retirement's perf payoff. The original
      # target was `<= 1.5x` of stock-rspec; structural Rails-boot floor caps the
      # achievable wall-clock ratio for this per-iter-subprocess shape
      # at ~1.6x (per-example tracer optimizations barely move a
      # scenario dominated by boot cost, so Rails boot is the floor). The
      # `cold_rails_v2_warm_iter` companion below measures the
      # amortized-boot variant where Rails loads ONCE in a long-running
      # parent process; that scenario captures the steady-state
      # per-rerun overhead users see in iterative dev loops, while
      # this scenario captures the cold-start cost users see in CI
      # post-checkout.
      desc: 'Cold start: Rails fixture, full spec/ tree (broader than cold_rails)',
      cwd: RAILS_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: {
        'RAILS_VERSION' => '~> 7.1.0',
        'RSPEC_RAILS_VERSION' => '~> 6.1.0',
        'SQLITE3_VERSION' => '~> 1.4',
        'RSPEC_TRACER' => '1'
      },
      cleanup: %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage coverage],
      setup: lambda do |cwd|
        system('bundle', 'exec', 'rails', 'db:test:prepare',
               chdir: cwd, out: File::NULL, err: File::NULL)
      end,
      smoke: false
    },
    'cold_rails_v2_warm_iter' => {
      # Long-running parent-process variant of cold_rails_v2. Boots
      # Rails ONCE in the parent, then fork()s for each measured
      # iteration. Iter timing captures rspec invocation +
      # rspec-tracer engine setup + per-example overhead, BUT
      # excludes the cold Rails boot (which is amortized across iters
      # in the parent). Captures the steady-state per-rerun cost users
      # see in iterative dev loops (where Spring or zeus-style
      # preloading would amortize boot the same way).
      #
      # Single Open3 invocation; the script emits N per-iter JSON
      # timings on stdout. Harness aggregates via the long_running
      # branch in run_scenario.
      desc: 'Long-running parent + fork-per-iter: amortizes Rails-boot, measures steady-state overhead',
      cwd: RAILS_FIXTURE,
      cmd: ['bundle', 'exec', 'ruby', File.join(REPO_ROOT, 'benchmark/scenarios/cold_rails_v2_warm_iter.rb')],
      env: {
        'RAILS_VERSION' => '~> 7.1.0',
        'RSPEC_RAILS_VERSION' => '~> 6.1.0',
        'SQLITE3_VERSION' => '~> 1.4',
        'RSPEC_TRACER' => '1',
        'RAILS_ENV' => 'test'
      },
      cleanup: %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage coverage],
      setup: lambda do |cwd|
        system('bundle', 'exec', 'rails', 'db:test:prepare',
               chdir: cwd, out: File::NULL, err: File::NULL)
      end,
      long_running: true,
      smoke: false
    },
    'coverage_adapter' => {
      desc: 'Microbenchmark: Tracker::CoverageAdapter#compute_diff × 100 files × 1000 iters',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/coverage_adapter.rb'],
      env: { 'ITERATIONS' => '1000' },
      smoke: false
    },
    'cache_load' => {
      # Contract: 500-example cache loads fast under the lazy +
      # string-interning path. Times N Storage::JsonBackend#load_graph
      # + full field materialization against a representative
      # populated cache. smoke:false because subprocess boot dominates
      # the inner work enough that 3-iter variance regularly trips
      # the harness fail ratio against its own ratchet. Runs in
      # benchmark:full and benchmark:ratchet:update.
      desc: 'Microbenchmark: Storage::JsonBackend#load_graph over a 500-example populated cache',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/cache_load.rb'],
      env: { 'ITERATIONS' => '20', 'BACKEND' => 'json', 'SERIALIZER' => 'json' },
      smoke: false
    },
    'cache_load_msgpack' => {
      # Same fixture as `cache_load`, with `:msgpack` serializer. Baseline
      # for the disk-reduction claim; also catches regressions in the
      # zlib + msgpack path at load time.
      desc: 'Microbenchmark: JsonBackend(serializer: :msgpack) load_graph over a 500-example populated cache',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/cache_load.rb'],
      env: { 'ITERATIONS' => '20', 'BACKEND' => 'json', 'SERIALIZER' => 'msgpack' },
      smoke: false
    },
    'cache_load_sqlite' => {
      # SqliteBackend variant. Verifies the normalized-schema load path
      # stays competitive with the JSON serializers at 500-example
      # scale; the RAM win dominates at larger sizes (not captured
      # here, the microbench is wall-clock focused).
      desc: 'Microbenchmark: Storage::SqliteBackend#load_graph over a 500-example populated cache',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/cache_load.rb'],
      env: { 'ITERATIONS' => '20', 'BACKEND' => 'sqlite' },
      smoke: false
    },
    'file_read_hook' => {
      desc: 'Microbenchmark: Tracker::IOHooks File.read overhead (reject + record paths)',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/file_read_hook.rb'],
      env: { 'REJECT_ITERS' => '100000', 'RECORD_ITERS' => '10000' },
      smoke: false
    },
    'loaded_files_tracker' => {
      desc: 'Microbenchmark: Tracker::LoadedFilesTracker#stop_example overhead (<=1ms AC gate)',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/loaded_files_tracker.rb'],
      env: { 'BOOT_FILES' => '500', 'STEADY_ITERS' => '10000', 'GROWING_ITERS' => '2000' },
      smoke: false
    }
  }.freeze

  module_function

  def run_rspec_once(cwd, env)
    Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color',
                    chdir: cwd)
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

  def environment
    {
      'ruby' => RUBY_VERSION,
      'ruby_platform' => RUBY_PLATFORM,
      'os' => RbConfig::CONFIG['host_os'].to_s,
      'cpu' => cpu_label,
      'cores' => Etc.nprocessors,
      'recorded_at' => Time.now.utc.iso8601
    }
  end

  def cpu_label
    if RbConfig::CONFIG['host_os'].include?('darwin')
      `/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip
    elsif File.exist?('/proc/cpuinfo')
      File.read('/proc/cpuinfo').match(/model name\s*:\s*(.+)/)&.[](1).to_s.strip
    else
      'unknown'
    end
  rescue StandardError
    'unknown'
  end

  # Cohesive enough that splitting hurts readability.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def run_scenario(name, spec, iterations:)
    warn "\n== #{name} (#{iterations} iters) — #{spec[:desc]}"

    unless File.exist?(File.join(spec[:cwd], 'Gemfile.lock'))
      warn "  skipping: #{spec[:cwd]}/Gemfile.lock missing — run bundle install first"
      return nil
    end

    # Optional setup (not timed): e.g. db:test:prepare.
    spec[:setup]&.call(spec[:cwd])

    # Warmup (not timed): e.g. populate cache for warm/cache-load scenarios.
    spec[:warmup]&.call(spec[:cwd])

    return run_scenario_long_running(name, spec, iterations: iterations) if spec[:long_running]

    timings = []
    iterations.times do |i|
      Array(spec[:cleanup]).each do |rel|
        FileUtils.rm_rf(File.join(spec[:cwd], rel))
      end
      elapsed = Benchmark.realtime do
        _out, status = Open3.capture2e(spec[:env], *spec[:cmd], chdir: spec[:cwd])
        unless status.success?
          warn "  iteration #{i + 1} failed (exit #{status.exitstatus}); aborting scenario"
          return nil
        end
      end
      timings << elapsed
      warn format('  iter %<n>d: %<t>.3fs', n: i + 1, t: elapsed)
    end

    {
      'scenario' => name,
      'iterations' => iterations,
      'timings' => timings.map { |t| t.round(4) },
      'p50' => median(timings).round(4),
      'p95' => percentile(timings, 95).round(4)
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Long-running variant: ONE Open3 call to a persistent parent
  # process; the script does N internal iterations and emits per-iter
  # JSON lines on stdout. We aggregate those instead of timing N
  # subprocess wall-clocks. The script self-cleans iter state so
  # spec[:cleanup] is unused here (the script knows what to wipe).
  # Per-iter wall-clock measured in the script EXCLUDES Rails-boot
  # (paid once at script start) — so the aggregated p50/p95 capture
  # steady-state overhead, not cold-start.
  def run_scenario_long_running(name, spec, iterations:)
    env = (spec[:env] || {}).merge('BENCH_ITERATIONS' => iterations.to_s)
    out, status = Open3.capture2e(env, *spec[:cmd], chdir: spec[:cwd])
    unless status.success?
      warn "  long-running script failed (exit #{status.exitstatus}); aborting scenario"
      warn out
      return nil
    end

    timings = parse_long_running_timings(out)
    if timings.empty?
      warn '  long-running script emitted no parseable timings; aborting scenario'
      warn out
      return nil
    end

    timings.each_with_index { |t, i| warn format('  iter %<n>d: %<t>.3fs', n: i + 1, t: t) }

    {
      'scenario' => name,
      'iterations' => timings.length,
      'timings' => timings.map { |t| t.round(4) },
      'p50' => median(timings).round(4),
      'p95' => percentile(timings, 95).round(4)
    }
  end

  # Parse `{"iter":N,"timing":F}` JSON lines from the script's stdout.
  # Tolerates extra non-JSON lines (Bundler messages, Rails warnings,
  # rspec progress dots etc.) by skipping them silently. Output may
  # carry non-ASCII bytes from rspec's UTF-8 progress glyphs - force
  # the encoding to UTF-8 before line iteration so US-ASCII-defaulted
  # parsers (mutant, frozen-string-literal Rubies) don't choke.
  def parse_long_running_timings(out)
    out.force_encoding('UTF-8').each_line.filter_map do |line|
      JSON.parse(line.strip)['timing']
    rescue JSON::ParserError, Encoding::CompatibilityError
      nil
    end.compact
  end

  def interpreter_multiplier
    INTERPRETER_RATCHET_MULTIPLIERS.fetch(RUBY_ENGINE, 1.0)
  end

  # True iff the current interpreter has an explicit non-canonical
  # multiplier configured (i.e. not the default 1.0 for MRI / unlisted
  # engines). Avoids `multiplier == 1.0` float-equality comparison
  # (Lint/FloatComparison) - we test membership + RUBY_ENGINE identity
  # instead, which is exact.
  def interpreter_scaling?
    RUBY_ENGINE != 'ruby' && INTERPRETER_RATCHET_MULTIPLIERS.key?(RUBY_ENGINE)
  end

  def compare_to_ratchet(results, ratchet)
    multiplier = interpreter_multiplier
    statuses = {}
    results.each do |result|
      name = result['scenario']
      base = ratchet.dig('scenarios', name, 'p50')
      next statuses[name] = :no_baseline unless base

      # Effective threshold is the canonical MRI ratchet scaled by the
      # current interpreter's multiplier. On MRI multiplier=1.0 so the
      # behavior is byte-identical to the pre-multiplier code; on JRuby /
      # TruffleRuby the threshold is scaled up to absorb interpreter
      # overhead without requiring per-interpreter ratchet entries.
      threshold = base * multiplier
      ratio = result['p50'] / threshold
      statuses[name] =
        if INFORMATIONAL_SCENARIOS.include?(name)
          { status: :informational, ratio: ratio, threshold: threshold }
        elsif ratio > REGRESSION_FAIL_RATIO then { status: :fail, ratio: ratio, threshold: threshold }
        elsif ratio > REGRESSION_WARN_RATIO then { status: :warn, ratio: ratio, threshold: threshold }
        else { status: :ok, ratio: ratio, threshold: threshold }
        end
    end
    statuses
  end

  def print_summary(results, statuses)
    if interpreter_scaling?
      warn format("\n== Summary (RUBY_ENGINE=%<engine>s, ratchet x%<m>.2f)",
                  engine: RUBY_ENGINE, m: interpreter_multiplier)
    else
      warn "\n== Summary"
    end
    results.each do |result|
      name = result['scenario']
      status = statuses[name]
      line = format('  %<name>-14s p50=%<p50>.3fs p95=%<p95>.3fs',
                    name: name, p50: result['p50'], p95: result['p95'])
      if status.is_a?(Hash)
        label = status[:status] == :informational ? 'INFO (not gated)' : status[:status].upcase
        line += format('  [%<ratio>.2fx threshold %<threshold>.3fs] %<status>s',
                       ratio: status[:ratio], threshold: status[:threshold],
                       status: label)
      end
      warn line
    end
  end

  def load_ratchet(path)
    return nil unless path && File.exist?(path)

    parsed = JSON.parse(File.read(path))
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    warn "ratchet at #{path} is not valid JSON; ignoring"
    nil
  end

  def write_ratchet(path, results)
    payload = {
      'environment' => environment,
      'scenarios' => results.to_h do |r|
                       [r['scenario'], { 'p50' => r['p50'], 'p95' => r['p95'], 'iterations' => r['iterations'] }]
                     end
    }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(payload)}\n")
    warn "\nRatchet written to #{path}"
  end

  def summary_row(result, status)
    status_cell =
      if status.is_a?(Hash)
        icon = STATUS_ICONS.fetch(status[:status], '?')
        "#{icon} #{format('%<r>.2fx', r: status[:ratio])}"
      else
        '—'
      end
    threshold = status.is_a?(Hash) ? format('%<t>.3f', t: status[:threshold]) : '—'
    "| `#{result['scenario']}` | #{format('%<p>.3f', p: result['p50'])} | " \
      "#{format('%<p>.3f', p: result['p95'])} | #{threshold} | #{status_cell} |"
  end

  def write_markdown_summary(path, results, statuses, ratchet)
    env = environment
    rows = results.map { |r| summary_row(r, statuses[r['scenario']]) }
    multiplier_note = if interpreter_scaling?
                        format(
                          ' Ratchet thresholds scaled x%<m>.2f for `RUBY_ENGINE=%<engine>s`.',
                          m: interpreter_multiplier, engine: RUBY_ENGINE
                        )
                      else
                        ''
                      end
    body = [
      '## Benchmark results',
      '',
      "Run on Ruby `#{env['ruby']}` / `#{env['cpu']}` / #{env['cores']} cores / `#{env['os']}`.#{multiplier_note}",
      '',
      '| Scenario | P50 (s) | P95 (s) | Ratchet P50 | vs Ratchet |',
      '|---|---|---|---|---|',
      *rows,
      '',
      'Thresholds: ≤ 1.10× silent pass · 1.10–1.30× warning · > 1.30× fail. ' \
      "Scenarios marked INFO are reported but not gated (see #{INFORMATIONAL_SCENARIOS.join(', ')})."
    ]
    body << '' << 'No ratchet loaded — comparison skipped.' if ratchet.nil?
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{body.join("\n")}\n")
  end

  def parse_options(argv)
    options = {
      mode: nil, ratchet: nil, update_ratchet: nil, summary_md: nil,
      iterations: nil, confirm_update: false, enforce: true
    }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby benchmark/harness.rb [OPTIONS]'
      opts.on('--smoke', 'Fast scenarios only (iters=3)') { options[:mode] = :smoke }
      opts.on('--full', 'All scenarios') { options[:mode] = :full }
      opts.on('--ratchet PATH', 'Compare to ratchet JSON') { |p| options[:ratchet] = p }
      opts.on('--update-ratchet PATH', 'Write ratchet JSON from this run') { |p| options[:update_ratchet] = p }
      opts.on('--summary-md PATH', 'Markdown summary for CI comments') { |p| options[:summary_md] = p }
      opts.on('--iterations N', Integer, 'Override iteration count') { |n| options[:iterations] = n }
      opts.on('--no-enforce', 'Print ratchet comparison; do not exit non-zero') { options[:enforce] = false }
      opts.on('--yes', 'Confirm ratchet overwrite') { options[:confirm_update] = true }
    end
    parser.parse!(argv)
    validate_options!(options, parser)
    options
  end

  def validate_options!(options, parser)
    unless %i[smoke full].include?(options[:mode])
      warn parser.help
      exit 1
    end
    return unless options[:update_ratchet] && !options[:confirm_update]

    warn '--update-ratchet requires --yes (prevents accidental threshold bumps)'
    exit 1
  end

  def execute_scenarios(options)
    iterations = options[:iterations] ||
      (options[:mode] == :smoke ? DEFAULT_ITERATIONS_SMOKE : DEFAULT_ITERATIONS_FULL)
    scenarios = SCENARIOS.select { |_, spec| options[:mode] == :full || spec[:smoke] }
    scenarios.filter_map do |name, spec|
      result = run_scenario(name, spec, iterations: iterations)
      next unless result

      puts JSON.generate(result.merge('env' => environment))
      result
    end
  end

  def main(argv = ARGV)
    options = parse_options(argv)
    results = execute_scenarios(options)

    if options[:update_ratchet]
      write_ratchet(options[:update_ratchet], results)
      exit 0
    end

    ratchet = load_ratchet(options[:ratchet])
    statuses = ratchet ? compare_to_ratchet(results, ratchet) : {}
    print_summary(results, statuses)
    write_markdown_summary(options[:summary_md], results, statuses, ratchet) if options[:summary_md]

    any_fail = statuses.values.any? { |s| s.is_a?(Hash) && s[:status] == :fail }
    exit(1) if any_fail && options[:enforce]
  end
end
# rubocop:enable Metrics/ModuleLength

BenchmarkHarness.main if $PROGRAM_NAME == __FILE__
