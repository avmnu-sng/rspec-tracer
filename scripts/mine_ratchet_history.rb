#!/usr/bin/env ruby
# frozen_string_literal: true

# Mine historical benchmark runs from GitHub Actions to populate a
# multi-run sample without re-running benchmarks. Per-run benchmark
# stdout already emits one JSON-line per scenario (see
# benchmark/harness.rb#run_scenario); this script:
#
#   1. Lists recent CI runs via `gh run list` (main + closed PRs).
#   2. For each run, finds the `full-matrix / benchmark` job and
#      pulls the log via `gh run view --job <id> --log`.
#   3. Greps the per-scenario JSON lines from the log.
#   4. Synthesizes a per-run ratchet.json under a temp dir keyed by
#      run id, containing an `environment` block (CPU model, OS) +
#      a `scenarios` block (p50 + p95 per scenario).
#   5. Hands the temp dir to scripts/aggregate_ratchet.rb to compute
#      the multi-run baseline.
#
# Cutoff: only mine runs with head_sha at or after the perf-stable
# cutoff (default: e574f6f, M8.4-A merge 2026-04-29). Earlier runs
# represent different lib perf shape and would mis-calibrate.
#
# Usage:
#   ruby scripts/mine_ratchet_history.rb \
#     --cutoff-sha e574f6f \
#     --target-runs 30 \
#     --tmp-dir tmp/mined-ratchet
#
# Then invoke the aggregator on the tmp dir:
#   ruby scripts/aggregate_ratchet.rb \
#     --runs-dir tmp/mined-ratchet \
#     --out tmp/candidate-ratchet.json \
#     --summary tmp/candidate-summary.md \
#     --baseline-percentile 95

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'tmpdir'

DEFAULT_CUTOFF_SHA = 'e574f6f' # M8.4-A merge — perf-stable baseline
DEFAULT_TARGET_RUNS = 30
WORKFLOW_FILE = 'ci.yml'
BENCHMARK_JOB_NAME = 'full-matrix / benchmark'
SCENARIO_LINE_RX = /\{"scenario":[^}]+"env":\{[^}]+\}\}/

RETRY_BACKOFFS = [1, 3, 8].freeze

def gh_capture(args)
  attempt = 0
  loop do
    out, err, status = Open3.capture3('gh', *args)
    return out.force_encoding('UTF-8').scrub if status.success?

    attempt += 1
    backoff = RETRY_BACKOFFS[attempt - 1]
    if backoff && (err.include?('502') || err.include?('503') || err.include?('timeout'))
      warn "  gh transient failure (attempt #{attempt}); sleeping #{backoff}s"
      sleep backoff
      next
    end
    raise "gh failed: #{args.inspect}\nstderr: #{err}"
  end
end

def gh_json(args)
  JSON.parse(gh_capture(args))
end

def gh_text(args)
  gh_capture(args)
end

def commit_committed_at_or_after(sha, cutoff_committer_date)
  out, status = Open3.capture2('git', 'show', '-s', '--format=%cI', sha)
  return false unless status.success?

  Time.parse(out.strip) >= cutoff_committer_date
rescue StandardError
  false
end

def list_candidate_runs(cutoff_sha:, target:, repo:)
  cutoff_date = Time.parse(gh_text(['api', "repos/#{repo}/commits/#{cutoff_sha}", '--jq',
                                    '.commit.committer.date']).strip)
  warn "Cutoff: #{cutoff_sha} committed at #{cutoff_date}"

  page_size = [target * 4, 100].min
  runs = gh_json([
    'run', 'list',
    '--repo', repo,
    '--workflow', WORKFLOW_FILE,
    '--status', 'completed',
    '--limit', page_size.to_s,
    '--json', 'databaseId,headSha,createdAt,event,conclusion'
  ])

  runs.select { |r| commit_committed_at_or_after(r['headSha'], cutoff_date) }
end

def find_benchmark_job(run_id, repo)
  jobs = gh_json([
    'run', 'view', run_id.to_s,
    '--repo', repo,
    '--json', 'jobs'
  ]).fetch('jobs', [])
  jobs.find { |j| j['name'] == BENCHMARK_JOB_NAME }
end

def fetch_log(job_id, repo)
  gh_text(['run', 'view', '--repo', repo, '--job', job_id.to_s, '--log'])
rescue StandardError => e
  warn "  log fetch failed (job=#{job_id}): #{e.message}"
  nil
end

def parse_scenario_lines(log)
  log.scan(SCENARIO_LINE_RX).filter_map do |raw|
    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end
end

def write_synthesized_ratchet(scenarios, out_path)
  return if scenarios.empty?

  env = scenarios.first.fetch('env')
  payload = {
    'environment' => env,
    'scenarios' => scenarios.to_h do |s|
      [
        s.fetch('scenario'),
        { 'p50' => s.fetch('p50'), 'p95' => s.fetch('p95'), 'iterations' => s.fetch('iterations') }
      ]
    end
  }
  FileUtils.mkdir_p(File.dirname(out_path))
  File.write(out_path, "#{JSON.pretty_generate(payload)}\n")
end

def parse_options(argv)
  options = {
    cutoff_sha: DEFAULT_CUTOFF_SHA,
    target_runs: DEFAULT_TARGET_RUNS,
    tmp_dir: 'tmp/mined-ratchet',
    repo: 'avmnu-sng/rspec-tracer'
  }
  OptionParser.new do |o|
    o.on('--cutoff-sha SHA', 'Mine only runs at or after this commit (perf-stable cutoff)') do |v|
      options[:cutoff_sha] = v
    end
    o.on('--target-runs N', Integer, "Target N usable runs (default #{DEFAULT_TARGET_RUNS})") do |v|
      options[:target_runs] = v
    end
    o.on('--tmp-dir DIR', 'Where to write per-run ratchet.json files') { |v| options[:tmp_dir] = v }
    o.on('--repo REPO', 'GitHub repo (owner/name)') { |v| options[:repo] = v }
  end.parse!(argv)
  options
end

options = parse_options(ARGV)
FileUtils.mkdir_p(options[:tmp_dir])

candidate_runs = list_candidate_runs(
  cutoff_sha: options[:cutoff_sha],
  target: options[:target_runs],
  repo: options[:repo]
)
warn "Found #{candidate_runs.size} candidate runs at or after cutoff #{options[:cutoff_sha]}"

mined = 0
candidate_runs.each do |run|
  break if mined >= options[:target_runs]

  warn "[#{mined + 1}] run=#{run['databaseId']} sha=#{run['headSha'][0, 7]} event=#{run['event']}"
  job = find_benchmark_job(run['databaseId'], options[:repo])
  unless job
    warn '  no benchmark job; skip'
    next
  end
  if job['conclusion'] != 'success' && job['conclusion'] != 'failure'
    # 'failure' is OK — the run still produced JSON lines before
    # the ratchet check failed. Cancelled/skipped have no usable data.
    warn "  benchmark job inconclusive (#{job['conclusion']}); skip"
    next
  end

  log = fetch_log(job['databaseId'], options[:repo])
  next if log.nil?

  scenarios = parse_scenario_lines(log)
  if scenarios.empty?
    warn '  no scenario JSON lines parsed; skip'
    next
  end

  out_path = File.join(options[:tmp_dir], "run-#{run['databaseId']}", 'ratchet.json')
  write_synthesized_ratchet(scenarios, out_path)
  warn "  -> wrote #{scenarios.size} scenarios from cpu=#{scenarios.first.dig('env', 'cpu')}"
  mined += 1
end

warn "\nMined #{mined} usable runs into #{options[:tmp_dir]}/"
warn 'Next: ruby scripts/aggregate_ratchet.rb ' \
     "--runs-dir #{options[:tmp_dir]} " \
     '--out tmp/candidate-ratchet.json ' \
     '--summary tmp/candidate-summary.md ' \
     '--baseline-percentile 95'
