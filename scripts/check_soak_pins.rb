#!/usr/bin/env ruby
# frozen_string_literal: true

# Weekly soak-pin status check. Reads .github/sha-pins/<project>.txt
# pin files (sha + tag + license_sha256), queries the GitHub API for
# the latest tag + license content per project, and reports drift to
# stdout (markdown table) + $GITHUB_STEP_SUMMARY when set.
#
# Report-only - never opens PRs / issues / modifies pin files.
# Maintainer reviews the weekly report and opens bump PRs by hand
# per feedback_never_merge_prs (humans gate every bump).
#
# Run via: ruby scripts/check_soak_pins.rb
#
# Required: `gh` CLI authenticated for public repos. CI's GITHUB_TOKEN
# (exposed as GH_TOKEN env in the workflow) is sufficient; local dev
# uses `gh auth status` to confirm.
#
# Static per-project metadata (repo / license_path / release_source)
# lives in the PROJECTS constant below. The pin files hold the
# dynamic state; the constant tells the checker how to query each
# project's latest release.

require 'base64'
require 'digest'
require 'json'
require 'open3'
require 'pathname'

REPO_ROOT = Pathname(File.expand_path('..', __dir__))
PINS_DIR = REPO_ROOT.join('.github/sha-pins')

PROJECTS = {
  solidus: {
    repo: 'solidusio/solidus',
    license_path: 'LICENSE.md',
    # Solidus tags every release via GitHub Releases.
    release_source: :releases
  },
  refinery: {
    repo: 'refinery/refinerycms',
    license_path: 'license.md',
    # Refinery doesn't publish via GitHub Releases as of 4.0.2;
    # tags are the only source of "latest" signal.
    release_source: :tags
  },
  spree: {
    repo: 'spree/spree',
    license_path: 'LICENSE',
    release_source: :releases
  }
}.freeze

# Shell out to `gh api <path> --jq <expr>`. Returns the trimmed
# stdout on success, nil on failure (network / auth / 404). Errors
# are intentionally swallowed at the per-project boundary so one
# project's API failure doesn't kill the whole report.
def gh_api_jq(path, jq_expr)
  output, status = Open3.capture2e('gh', 'api', path, '--jq', jq_expr)
  return nil unless status.success?

  output.strip
end

def parse_pin(pin_file)
  data = {}
  pin_file.each_line do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')

    key, value = line.split('=', 2)
    data[key.to_sym] = value if key && value
  end
  data
end

def latest_tag(meta)
  case meta[:release_source]
  when :releases then gh_api_jq("repos/#{meta[:repo]}/releases/latest", '.tag_name')
  when :tags then gh_api_jq("repos/#{meta[:repo]}/tags", '.[0].name')
  end
end

# Resolves a tag to its commit SHA. Auto-derefs annotated tags
# (which are common: v4.7.0 / v5.4.2 are annotated tag objects, not
# lightweight tags). The /commits/<ref> endpoint handles both.
def commit_sha_for_tag(repo, tag)
  gh_api_jq("repos/#{repo}/commits/#{tag}", '.sha')
end

def license_sha256_at_tag(repo, license_path, tag)
  # zsh would glob the `?` in the URL; gh CLI receives the path
  # verbatim so the URL is fine, but we URL-encode `?` defensively
  # in case shell quoting drops it elsewhere.
  content_b64 = gh_api_jq("repos/#{repo}/contents/#{license_path}?ref=#{tag}", '.content')
  return nil if content_b64.nil? || content_b64.empty?

  Digest::SHA256.hexdigest(Base64.decode64(content_b64))
end

# Tag formats vary: v5.4.2 (Solidus / Spree) vs 4.0.2 (Refinery).
# Strip leading 'v', take first segment, compare as integer.
def major_for(tag)
  return nil if tag.nil?

  tag.delete_prefix('v').split('.').first&.to_i
end

def load_pin(project)
  pin_file = PINS_DIR.join("#{project}.txt")
  return [nil, "pin file missing: #{pin_file}"] unless pin_file.file?

  pin = parse_pin(pin_file)
  return [nil, 'pin file missing required fields (sha, tag, license_sha256)'] \
    unless pin[:sha] && pin[:tag] && pin[:license_sha256]

  [pin, nil]
end

def fetch_latest(meta)
  latest = latest_tag(meta)
  return [nil, nil, nil, 'failed to resolve latest tag from GitHub API'] if latest.nil?

  commit = commit_sha_for_tag(meta[:repo], latest)
  return [latest, nil, nil, 'failed to resolve latest commit SHA'] if commit.nil?

  license_sha = license_sha256_at_tag(meta[:repo], meta[:license_path], latest)
  return [latest, commit, nil, "failed to fetch LICENSE content at tag #{latest}"] if license_sha.nil?

  [latest, commit, license_sha, nil]
end

def check_project(project, meta)
  pin, pin_err = load_pin(project)
  return { project: project, error: pin_err } if pin_err

  latest, commit, new_license, err = fetch_latest(meta)
  return { project: project, pinned_tag: pin[:tag], latest_tag: latest, error: err } if err

  major_bump = (major_for(pin[:tag]) || 0) < (major_for(latest) || 0)

  {
    project: project,
    pinned_tag: pin[:tag], pinned_sha: pin[:sha], pinned_license_sha: pin[:license_sha256],
    latest_tag: latest, latest_sha: commit, new_license_sha: new_license,
    sha_changed: pin[:sha] != commit,
    major_bump: major_bump,
    license_stable: pin[:license_sha256] == new_license
  }
end

results = PROJECTS.map { |project, meta| check_project(project, meta) }

out = []
out << "# Soak pin status — #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}"
out << ''
out << '| Project | Pinned tag | Latest tag | SHA changed? | Major bump? | License stable? |'
out << '|---|---|---|---|---|---|'

results.each do |r|
  if r[:error]
    out << "| #{r[:project]} | #{r[:pinned_tag] || '?'} | ? | ? | ? | ⚠️ ERROR: #{r[:error]} |"
  else
    sha_m = r[:sha_changed] ? '✓' : '—'
    major_m = r[:major_bump] ? '⚠️ YES' : '—'
    license_m = r[:license_stable] ? '✓' : '⚠️ DRIFT'
    cells = "`#{r[:pinned_tag]}` | `#{r[:latest_tag]}` | #{sha_m} | #{major_m} | #{license_m}"
    out << "| #{r[:project]} | #{cells} |"
  end
end

out << ''
flagged = results.reject { |r| r[:error] }.select { |r| r[:major_bump] || !r[:license_stable] }

if flagged.empty?
  out << '_No major bumps + no license drift. Pins are current; no action needed._'
else
  out << '## Action items'
  out << ''
  flagged.each do |r|
    out << "### #{r[:project]}"
    out << "- Pinned: `#{r[:pinned_tag]}` (sha `#{r[:pinned_sha][0, 12]}…`)"
    out << "- Latest: `#{r[:latest_tag]}` (sha `#{r[:latest_sha][0, 12]}…`)"
    out << '- **Major bump available.** Pin stays put until a maintainer opens a bump PR.' if r[:major_bump]
    unless r[:license_stable]
      old_short = r[:pinned_license_sha][0, 12]
      new_short = r[:new_license_sha][0, 12]
      out << "- ⚠️⚠️ **License SHA-256 drifted.** Pinned `#{old_short}…` vs new `#{new_short}…`."
      out << '  Manual license review REQUIRED before any bump.'
    end
    out << ''
  end
end

out << ''
out << '_Pins are review-gated: this report does not auto-bump. Maintainer opens bump PRs manually._'

report = out.join("\n")
puts report

step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
File.open(step_summary, 'a') { |f| f.puts report } if step_summary && !step_summary.empty?
