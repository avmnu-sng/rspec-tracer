#!/usr/bin/env ruby
# frozen_string_literal: true

# Internal-nomenclature leak gate: scans every tracked file for
# private planning vocabulary that must not ship in the public repo
# (milestone tags, private note names, local-only doc-tree paths).
#
# Two passes:
#   1. `git grep -nEI <pattern>` over all tracked files for the
#      single-line patterns below.
#   2. A split-rendering pass over tracked *.md files that catches
#      directory-tree drawings where `docs/` and `revamp` land on
#      neighboring lines (within 2 lines) and therefore dodge the
#      single-line pattern.
#
# Exemptions live in .leakcheck-allow at the repo root: one path or
# glob per line, each with a MANDATORY trailing `# justification`
# comment. Entries without a justification fail the gate.
#
# CHANGELOG.md gets a section-scoped rule instead of a whole-path
# exemption: everything above the first released-version heading
# (the active [Unreleased] block, where new text lands) is scanned
# with the full pattern set; only the shipped-history sections below
# it are exempt, because released entries are frozen text that is
# never rewritten retroactively.
#
# Run via: task docs:leak-check
#
# Exits 0 when clean, 1 on any unallowed hit or malformed allowlist.

require 'open3'
require 'pathname'

ROOT = Pathname(File.expand_path('..', __dir__))
ALLOWLIST_PATH = ROOT.join('.leakcheck-allow')

# Single-line leak patterns, joined into one alternation for
# `git grep -E`. This file is itself exempted in .leakcheck-allow:
# the gate has to spell out the patterns it hunts.
LEAK_PATTERN = [
  'M[0-9]+\.[0-9]+(-[A-Z])?', # milestone tags from the private plan
  'docs/revamp',              # local-only planning tree
  'kickoff',                  # session-planning vocabulary
  'feedback_[a-z_]+',         # private maintainer-note names
  'personal-install',         # private distribution vocabulary
  # Private bug/question/followup/criterion tags (B10, Q6, F4, C3).
  # Word boundaries are spelled as character classes, NOT \b: BSD
  # regex (git grep -E on macOS) has no \b, so a \b-based pattern
  # silently matches nothing locally while GNU regex on Linux CI
  # matches: exactly the local/CI divergence this gate exists to
  # prevent. `#` is excluded from the left boundary so CSS hex
  # colors (e.g. #B00100 in fixture error pages) cannot match.
  '(^|[^[:alnum:]_#])[BQFC][0-9]+([^[:alnum:]_]|$)'
].join('|').freeze

def load_allowlist
  entries = []
  errors = []
  return [entries, errors] unless ALLOWLIST_PATH.file?

  ALLOWLIST_PATH.each_line.with_index(1) do |line, lineno|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?('#')

    match = stripped.match(/\A(?<glob>\S+)\s+#\s*\S.*\z/)
    if match
      entries << match[:glob]
    else
      errors << ".leakcheck-allow:#{lineno}: entry needs a trailing '# justification' comment: #{stripped}"
    end
  end
  [entries, errors]
end

ALLOW, ALLOWLIST_ERRORS = load_allowlist

def allowed?(path)
  ALLOW.any? do |glob|
    path == glob ||
      path.start_with?("#{glob}/") ||
      File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
      File.fnmatch?(glob, path, File::FNM_DOTMATCH)
  end
end

CHANGELOG_PATH = 'CHANGELOG.md'

# Line number (1-indexed) of the first released-version heading in
# CHANGELOG.md, e.g. `## [2.0.0.pre.2] - 2026-05-16`. Everything
# above it is the active [Unreleased] block and is scanned; the
# heading and everything below it are frozen shipped-history text
# and exempt. When no released heading exists yet, the whole file
# is live and gets scanned.
def changelog_frozen_from
  @changelog_frozen_from ||= begin
    changelog = ROOT.join(CHANGELOG_PATH)
    # Explicit encoding + scrub: with no locale in the environment the
    # default external encoding is US-ASCII, and match? raises on the
    # changelog's UTF-8 punctuation.
    lines = (File.foreach(changelog, encoding: 'UTF-8').map(&:scrub) if changelog.file?)
    index = lines&.find_index { |line| line.match?(/\A##\s+\[\d/) }
    index ? index + 1 : Float::INFINITY
  end
end

def frozen_changelog_line?(path, lineno)
  path == CHANGELOG_PATH && lineno >= changelog_frozen_from
end

def single_line_hits
  out, err, status = Open3.capture3(
    'git', 'grep', '-nEI', LEAK_PATTERN, '--', '.', chdir: ROOT.to_s
  )
  # git grep exits 0 on hits, 1 on no hits, >1 on real errors.
  abort "leak-check: git grep failed (exit #{status.exitstatus}): #{err}" if status.exitstatus > 1

  out.each_line.with_object([]) do |line, hits|
    line = line.scrub
    path, lineno, = line.split(':', 3)
    next if allowed?(path) || frozen_changelog_line?(path, lineno.to_i)

    hits << line.chomp
  end
end

def tracked_markdown_files
  out, err, status = Open3.capture3('git', 'ls-files', '--', '*.md', chdir: ROOT.to_s)
  abort "leak-check: git ls-files failed (exit #{status.exitstatus}): #{err}" unless status.success?

  out.split("\n")
end

# Catches directory-tree drawings that split the local-only doc tree
# across lines, e.g. a `docs/` branch line followed by a `revamp/`
# leaf line one or two lines below.
def split_rendering_hits
  tracked_markdown_files.each_with_object([]) do |file, hits|
    next if allowed?(file)

    hits.concat(split_rendering_hits_in(file))
  end
end

def split_rendering_hits_in(file)
  lines = File.readlines(ROOT.join(file), chomp: true, encoding: 'UTF-8').map(&:scrub)
  lines.each_index.filter_map do |idx|
    next if frozen_changelog_line?(file, idx + 1)
    next unless lines[idx].include?('docs/')
    next if lines[idx, 3].none? { |nearby| nearby.include?('revamp') }

    "#{file}:#{idx + 1}: 'docs/' with 'revamp' within 2 lines (split tree rendering)"
  end
end

failures = ALLOWLIST_ERRORS + single_line_hits + split_rendering_hits

if failures.empty?
  puts 'leak check clean: no internal nomenclature in tracked files.'
  exit 0
end

warn "leak check found #{failures.length} unallowed hit(s):"
failures.each { |failure| warn "  #{failure}" }
warn ''
warn 'Rewrite the text to be self-contained, or (only with a real'
warn 'justification) add a path exemption to .leakcheck-allow.'
exit 1
