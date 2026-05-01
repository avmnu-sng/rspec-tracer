#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate N per-run ratchet.json captures into a single
# representative-baseline ratchet.json + a summary markdown.
#
# Usage:
#   ruby scripts/aggregate_ratchet.rb \
#     --runs-dir tmp/multi-run-ratchet \
#     --out benchmark/ratchet.json \
#     --summary $GITHUB_STEP_SUMMARY \
#     [--baseline-percentile 95]
#
# Why N runs: GHA `ubuntu-latest` mixes EPYC 9V74 (Zen 4) + EPYC 7763
# (Zen 3) + occasional Intel Xeon - CPU-microbench scenarios shift
# 15-25% across SKUs. Single-run baseline seeding bakes in whichever
# silicon GHA happened to allocate. N runs sample the SKU mix; an
# across-runs percentile threshold absorbs runner-pool heterogeneity.
#
# Why p95-of-p50: 95% of runs land at-or-below this baseline, going
# silent OK; the 5% tail (slowest SKU on a noisy day) goes WARN/FAIL
# but doesn't define the threshold. p50-of-p50 would WARN half the
# runs (defeats the gate); max-of-p50 would let one slow outlier
# define the threshold (gating becomes useless).
#
# What the summary captures: full distribution per scenario
# (min/p50/p75/p90/p95/p99/max) so the maintainer can sanity-check
# the spread + drift over time, plus the distinct CPU models seen +
# their per-scenario p50-of-p50.

require 'json'
require 'optparse'
require 'time'

DEFAULT_BASELINE_PERCENTILE = 95
DEFAULT_PERCENTILES = [50, 75, 90, 95, 99].freeze

def percentile(sorted, pct)
  return nil if sorted.empty?
  return sorted.first if sorted.size == 1

  idx_f = (pct / 100.0) * (sorted.size - 1)
  lower = idx_f.floor
  upper = idx_f.ceil
  return sorted[lower] if lower == upper

  weight = idx_f - lower
  ((sorted[lower] * (1.0 - weight)) + (sorted[upper] * weight)).round(4)
end

def parse_options(argv)
  options = { baseline_percentile: DEFAULT_BASELINE_PERCENTILE }
  OptionParser.new do |o|
    o.on('--runs-dir DIR', 'Directory containing per-run subdirs each with ratchet.json') do |v|
      options[:runs_dir] = v
    end
    o.on('--out PATH', 'Output candidate ratchet.json path') { |v| options[:out] = v }
    o.on('--summary PATH', 'Markdown summary output path (e.g. $GITHUB_STEP_SUMMARY)') do |v|
      options[:summary] = v
    end
    o.on('--baseline-percentile N', Integer, 'Across-runs percentile for threshold (default 95)') do |v|
      options[:baseline_percentile] = v
    end
  end.parse!(argv)
  options
end

def load_runs(runs_dir)
  Dir[File.join(runs_dir, '*', 'ratchet.json')].map do |path|
    JSON.parse(File.read(path)).merge('source_path' => path)
  end
end

def aggregate(runs, baseline_percentile)
  scenario_names = runs.flat_map { |r| r.fetch('scenarios').keys }.uniq.sort
  cpus = runs.map { |r| r.dig('environment', 'cpu') }.tally
  scenarios = scenario_names.to_h do |name|
    p50_samples = runs.filter_map { |r| r.dig('scenarios', name, 'p50') }.sort
    p95_samples = runs.filter_map { |r| r.dig('scenarios', name, 'p95') }.sort
    [name, summarize(name, p50_samples, p95_samples, baseline_percentile, runs.size)]
  end
  { 'scenarios' => scenarios, 'cpus' => cpus, 'run_count' => runs.size }
end

def summarize(name, p50_samples, p95_samples, baseline_percentile, run_count)
  baseline_p50 = percentile(p50_samples, baseline_percentile)
  baseline_p95 = percentile(p95_samples, baseline_percentile)
  {
    'name' => name,
    'observed_runs' => p50_samples.size,
    'missing_runs' => run_count - p50_samples.size,
    'baseline_p50' => baseline_p50,
    'baseline_p95' => baseline_p95,
    'p50_distribution' => DEFAULT_PERCENTILES.to_h { |p| ["p#{p}", percentile(p50_samples, p)] }
      .merge('min' => p50_samples.first, 'max' => p50_samples.last),
    'p95_distribution' => DEFAULT_PERCENTILES.to_h { |p| ["p#{p}", percentile(p95_samples, p)] }
      .merge('min' => p95_samples.first, 'max' => p95_samples.last)
  }
end

def write_candidate_ratchet(out_path, agg, baseline_percentile, sample_environment)
  payload = {
    'environment' => sample_environment.merge(
      'recorded_at' => Time.now.utc.iso8601,
      'baseline_methodology' => {
        'across_runs' => agg.fetch('run_count'),
        'baseline_percentile' => baseline_percentile,
        'cpus_seen' => agg.fetch('cpus')
      }
    ),
    'scenarios' => agg.fetch('scenarios').to_h do |name, summary|
                     [name, {
                       'p50' => summary.fetch('baseline_p50'),
                       'p95' => summary.fetch('baseline_p95'),
                       'iterations' => 10
                     }]
                   end
  }
  File.write(out_path, "#{JSON.pretty_generate(payload)}\n")
end

def summary_header(agg, baseline_percentile)
  buf = +''
  buf << "## Multi-run ratchet aggregation\n\n"
  buf << "- **Runs:** #{agg.fetch('run_count')}\n"
  buf << "- **Baseline percentile:** p#{baseline_percentile} across runs of within-run-p50\n"
  buf << "- **CPU models seen:**\n"
  agg.fetch('cpus').each { |cpu, count| buf << "  - `#{cpu}` (#{count} runs)\n" }
  buf
end

def summary_row(name, summary)
  dist = summary.fetch('p50_distribution')
  obs = "#{summary.fetch('observed_runs')}/#{summary.fetch('observed_runs') + summary.fetch('missing_runs')}"
  "| `#{name}` | #{format('%.4f', dist['min'])} | #{format('%.4f', dist['p50'])} " \
    "| #{format('%.4f', dist['p75'])} | #{format('%.4f', dist['p90'])} " \
    "| **#{format('%.4f', summary.fetch('baseline_p50'))}** " \
    "| #{format('%.4f', dist['p99'])} | #{format('%.4f', dist['max'])} | #{obs} |\n"
end

def write_summary(summary_path, agg, baseline_percentile)
  out = +''
  out << summary_header(agg, baseline_percentile)
  out << "\n### Per-scenario p50 distribution across runs\n\n"
  out << "| Scenario | min | p50 | p75 | p90 | p95 (baseline) | p99 | max | observed |\n"
  out << "|---|---|---|---|---|---|---|---|---|\n"
  agg.fetch('scenarios').each { |name, summary| out << summary_row(name, summary) }
  out << "\n_Threshold = p#{baseline_percentile}-of-p50 across runs. " \
         "Per scenario, #{baseline_percentile}% of runs land at or below this value._\n"
  File.write(summary_path, out)
end

options = parse_options(ARGV)
%i[runs_dir out summary].each do |k|
  abort("missing --#{k.to_s.tr('_', '-')}") if options[k].nil?
end

runs = load_runs(options[:runs_dir])
abort("no ratchet.json files found under #{options[:runs_dir]}") if runs.empty?

agg = aggregate(runs, options[:baseline_percentile])
sample_env = runs.first.fetch('environment').except('cpu', 'cores', 'recorded_at')
write_candidate_ratchet(options[:out], agg, options[:baseline_percentile], sample_env)
write_summary(options[:summary], agg, options[:baseline_percentile])

warn "candidate ratchet written to #{options[:out]} (p#{options[:baseline_percentile]} across #{runs.size} runs)"
agg.fetch('cpus').each { |cpu, n| warn "  cpu: #{cpu} (#{n} runs)" }
