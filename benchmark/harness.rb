# frozen_string_literal: true

# rspec-tracer benchmark harness.
#
# Measures rspec-tracer overhead across 4 scenarios and compares
# against a committed ratchet file. Builds fail if any scenario's
# median time exceeds the ratchet's P50 by > REGRESSION_FAIL_RATIO
# (20% by default). Warnings are emitted between REGRESSION_WARN_RATIO
# (10%) and REGRESSION_FAIL_RATIO.
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

module BenchmarkHarness
  REPO_ROOT = File.expand_path('..', __dir__)
  RUBY_FIXTURE = File.join(REPO_ROOT, 'benchmark/fixtures/ruby_app')
  RAILS_FIXTURE = File.join(REPO_ROOT, 'spec/fixtures/rails_app')

  REGRESSION_WARN_RATIO = 1.10
  REGRESSION_FAIL_RATIO = 1.20

  DEFAULT_ITERATIONS_FULL = 5
  DEFAULT_ITERATIONS_SMOKE = 3

  STATUS_ICONS = { ok: '✓', warn: '⚠', fail: '✗' }.freeze

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
    'cold_ruby_v2' => {
      desc: 'Cold start (v2 engine): RSPEC_TRACER_USE_V2_TRACKER=true',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: { 'RSPEC_TRACER_USE_V2_TRACKER' => 'true' },
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
    'warm_noop_v2' => {
      desc: 'Warm run (v2 engine): same fixture, cache populated, no file changes',
      cwd: RUBY_FIXTURE,
      cmd: %w[bundle exec rspec --no-color],
      env: { 'RSPEC_TRACER_USE_V2_TRACKER' => 'true' },
      warmup: ->(cwd) { run_rspec_once(cwd, 'RSPEC_TRACER_USE_V2_TRACKER' => 'true') },
      smoke: true
    },
    'cache_load' => {
      desc: 'Cache-only boot: load + populate cache, no specs',
      cwd: RUBY_FIXTURE,
      cmd: ['bundle', 'exec', 'ruby', '-e', <<~RUBY],
        require "rspec_tracer"
        cache_dir = File.join(Dir.pwd, "rspec_tracer_cache")
        if Dir.exist?(cache_dir)
          RSpecTracer::Cache.new.populate_from_disk(cache_dir)
        end
      RUBY
      env: {},
      warmup: ->(cwd) { run_rspec_once(cwd, {}) },
      smoke: true
    },
    'cold_rails' => {
      desc: 'Cold start: Rails fixture, empty cache',
      cwd: RAILS_FIXTURE,
      cmd: %w[bundle exec rspec --no-color spec/models],
      env: {
        'RAILS_VERSION' => '~> 7.1.0',
        'RSPEC_RAILS_VERSION' => '~> 6.1.0',
        'SIMPLECOV_VERSION' => '~> 0.22',
        'SQLITE3_VERSION' => '~> 1.4'
      },
      cleanup: %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage],
      setup: lambda do |cwd|
        system('bundle', 'exec', 'rails', 'db:test:prepare',
               chdir: cwd, out: File::NULL, err: File::NULL)
      end,
      smoke: false
    },
    'coverage_adapter' => {
      desc: 'Microbenchmark: Tracker::CoverageAdapter#compute_diff × 100 files × 1000 iters',
      cwd: REPO_ROOT,
      cmd: ['bundle', 'exec', 'ruby', 'benchmark/scenarios/coverage_adapter.rb'],
      env: { 'ITERATIONS' => '1000' },
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

  def compare_to_ratchet(results, ratchet)
    statuses = {}
    results.each do |result|
      name = result['scenario']
      threshold = ratchet.dig('scenarios', name, 'p50')
      next statuses[name] = :no_baseline unless threshold

      ratio = result['p50'] / threshold
      statuses[name] =
        if ratio > REGRESSION_FAIL_RATIO then { status: :fail, ratio: ratio, threshold: threshold }
        elsif ratio > REGRESSION_WARN_RATIO then { status: :warn, ratio: ratio, threshold: threshold }
        else { status: :ok, ratio: ratio, threshold: threshold }
        end
    end
    statuses
  end

  def print_summary(results, statuses)
    warn "\n== Summary"
    results.each do |result|
      name = result['scenario']
      status = statuses[name]
      line = format('  %<name>-14s p50=%<p50>.3fs p95=%<p95>.3fs',
                    name: name, p50: result['p50'], p95: result['p95'])
      if status.is_a?(Hash)
        line += format('  [%<ratio>.2fx threshold %<threshold>.3fs] %<status>s',
                       ratio: status[:ratio], threshold: status[:threshold],
                       status: status[:status].upcase)
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
    body = [
      '## Benchmark results',
      '',
      "Run on Ruby `#{env['ruby']}` / `#{env['cpu']}` / #{env['cores']} cores / `#{env['os']}`.",
      '',
      '| Scenario | P50 (s) | P95 (s) | Ratchet P50 | vs Ratchet |',
      '|---|---|---|---|---|',
      *rows,
      '',
      'Thresholds: ≤ 1.10× silent pass · 1.10–1.20× warning · > 1.20× fail.'
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

BenchmarkHarness.main if $PROGRAM_NAME == __FILE__
