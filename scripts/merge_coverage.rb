#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge multiple per-suite SimpleCov resultsets into one canonical
# `coverage/` directory (HTML + JSON formatters). Used by:
#
#   - `task coverage:merge` (local + CI aggregator job)
#   - the CI `coverage` job in lint-and-specs.yml after every test
#     job uploads its `coverage/.resultset.json` artifact
#
# SimpleCov.collate is the official cross-process merge primitive:
# it reads N resultsets, unions per-file line + branch coverage, and
# regenerates the formatters' output against the merged data.
#
# Inputs:
#   - Each per-suite resultset is expected at the path passed on
#     ARGV (typically `coverage_artifacts/coverage-<suite>/coverage/.resultset.json`).
#   - With no ARGV, defaults to globbing `coverage_artifacts/**/.resultset.json`
#     so the CI aggregator just downloads artifacts under that dir
#     and runs the script with no args.
#
# Output:
#   - coverage/index.html          (HTML report)
#   - coverage/coverage.json       (JSON report; codecov + dashboards)
#   - coverage/.last_run.json      (last-run summary)

require 'simplecov'
require 'simplecov_json_formatter'

resultsets = ARGV.empty? ? Dir['coverage_artifacts/**/.resultset.json'] : ARGV
abort 'no resultsets to collate' if resultsets.empty?

warn "Collating #{resultsets.size} resultset(s):"
resultsets.each { |p| warn "  #{p}" }

SimpleCov.collate(resultsets) do
  enable_coverage :branch

  # Match the per-suite filter list verbatim (.simplecov) so the
  # collated report reports the same surface. Without these, files
  # that one suite loaded but another suite filtered out would slip
  # back into the merged report.
  add_filter '/spec/'
  add_filter '/benchmark/'
  add_filter '/vendor/'
  add_filter '/tmp/'
  add_filter '/coverage/'
  add_filter %r{/lib/rspec_tracer/reporters/html/}
  # Metadata-only file (single VERSION constant). Mirrors the
  # codecov.yml + spec_helper.rb ignore lists.
  add_filter %r{/lib/rspec_tracer/version\.rb\z}

  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter
  ])
end
