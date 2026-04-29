#!/usr/bin/env ruby
# frozen_string_literal: true

# Bundle-drift check: verify every Gemfile in the repo resolves
# cleanly via a fresh `bundle install`. Closes the M2.1-M2.4
# absorbed orphan "Proper lockfile-drift check for `task check:bundle`".
#
# Original framing was "diff against committed Gemfile.lock" but every
# Gemfile.lock in this repo is gitignored (outer is library-style;
# fixtures are cross-interpreter). The meaningful drift signal is
# therefore "do these Gemfiles resolve cleanly on a fresh clone?" -
# which is what this script asserts.
#
# Run via: task check:bundle:drift
#
# Exits 0 on success, non-zero on the first Gemfile that fails to
# resolve. Output captured from each `bundle install` is printed only
# on failure (clean runs stay quiet to keep `task check:bundle:drift`
# usable in pre-PR parity scripts).

require 'bundler'
require 'open3'
require 'pathname'

ROOT = Pathname(File.expand_path('..', __dir__))
DEFAULT_GEMFILES = [
  ROOT.join('Gemfile'),
  ROOT.join('spec/fixtures/rails_app/Gemfile'),
  ROOT.join('spec/fixtures/rails_app_big/Gemfile'),
  ROOT.join('benchmark/fixtures/ruby_app/Gemfile')
].freeze

# Gemfiles to check: ARGV if provided (used by the drift spec to
# point at a temp Gemfile), otherwise the canonical set.
GEMFILES = ARGV.empty? ? DEFAULT_GEMFILES : ARGV.map { |a| Pathname(a) }

def check_gemfile(gemfile)
  return [false, "missing: #{gemfile}"] unless gemfile.file?

  dir = gemfile.dirname
  env = {
    'BUNDLE_GEMFILE' => gemfile.to_s,
    'BUNDLE_APP_CONFIG' => dir.join('.bundle').to_s
  }

  output, status = Bundler.with_unbundled_env do
    Open3.capture2e(env, 'bundle', 'install', '--jobs', '4', '--retry', '2',
                    chdir: dir.to_s)
  end

  return [true, nil] if status.success?

  [false, "exit #{status.exitstatus}\n#{output[-2_000..] || output}"]
end

failures = []
GEMFILES.each do |gemfile|
  print "drift check #{gemfile.relative_path_from(ROOT)} ... "
  ok, msg = check_gemfile(gemfile)
  if ok
    puts 'ok'
  else
    puts 'FAIL'
    failures << [gemfile, msg]
  end
end

if failures.empty?
  puts "\nAll #{GEMFILES.length} Gemfiles resolve cleanly."
  exit 0
end

warn "\n#{failures.length} Gemfile(s) failed to resolve:"
failures.each do |gemfile, msg|
  warn "\n--- #{gemfile.relative_path_from(ROOT)} ---"
  warn msg
end
exit 1
