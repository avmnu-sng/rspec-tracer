# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'

# Verifies the contract of `task docs:leak-check`
# (scripts/leak_check.rb): exit zero on a clean tree, non-zero on a
# leaked internal-nomenclature token, and -- the CHANGELOG-specific
# section rule -- non-zero on a leak in the active [Unreleased]
# block while shipped-history sections below the first
# released-version heading stay exempt.
#
# The script resolves its repo root relative to its own location, so
# each example copies it into a throwaway git repo and runs it
# there; the real repo's allowlist and content never interfere.
#
# The leak tokens planted in fixture files are built with string
# interpolation (never written literally) so this spec file itself
# stays clean under the real gate's scan.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations
# rubocop:disable RSpec/ExampleLength
RSpec.describe 'scripts/leak_check.rb' do
  # A milestone-style tag, assembled so the literal never appears in
  # this file: "M" + digits + "." + digits.
  let(:major) { 4 }
  let(:minor) { 2 }
  let(:milestone_token) { "M#{major}.#{minor}" }

  let(:script) { Pathname(__dir__).join('../../scripts/leak_check.rb').expand_path }

  let(:allowlist) do
    "scripts/leak_check.rb  # gate implementation; spells out the patterns it scans for\n"
  end

  # Suppress git background maintenance in the throwaway repo:
  # transient maintenance files (commit-graph, bitmap ref tips) race
  # with Dir.mktmpdir cleanup and raise ENOENT/ENOTEMPTY.
  def git_quiet_config
    %w[
      -c gc.auto=0 -c maintenance.auto=false
      -c core.commitGraph=false -c pack.writeBitmaps=false
    ]
  end

  def build_repo(dir, files)
    root = Pathname(dir)
    root.join('scripts').mkpath
    FileUtils.cp(script, root.join('scripts/leak_check.rb'))
    files.each do |path, content|
      target = root.join(path)
      target.dirname.mkpath
      target.write(content)
    end
    system('git', *git_quiet_config, 'init', '-q', chdir: dir) or raise 'git init failed'
    system('git', *git_quiet_config, 'add', '-A', chdir: dir) or raise 'git add failed'
    root
  end

  def run_gate(dir, files)
    root = build_repo(dir, files)
    Open3.capture2e('ruby', root.join('scripts/leak_check.rb').to_s)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  it 'exits zero on a clean tree' do
    output, status = run_gate(tmpdir, {
                                '.leakcheck-allow' => allowlist,
                                'README.md' => "A clean readme.\n"
                              })

    expect(status.exitstatus).to eq(0), "expected clean gate; got:\n#{output}"
    expect(output).to include('leak check clean')
  end

  it 'fails on a leaked token in an ordinary tracked file' do
    output, status = run_gate(tmpdir, {
                                '.leakcheck-allow' => allowlist,
                                'README.md' => "Shipped in #{milestone_token}.\n"
                              })

    expect(status.exitstatus).to eq(1)
    expect(output).to include('README.md:1')
  end

  it 'fails on a leak in the CHANGELOG [Unreleased] block' do
    changelog = <<~MD
      ## [Unreleased]

      - New thing (#{milestone_token}).

      ## [1.0.0] - 2021-10-21

      - Old release notes.
    MD
    output, status = run_gate(tmpdir, {
                                '.leakcheck-allow' => allowlist,
                                'CHANGELOG.md' => changelog
                              })

    expect(status.exitstatus).to eq(1)
    expect(output).to include('CHANGELOG.md:3')
  end

  it 'exempts shipped-history sections below the first released heading' do
    changelog = <<~MD
      ## [Unreleased]

      - Nothing yet.

      ## [1.0.0] - 2021-10-21

      - Old release notes mentioning #{milestone_token}.
    MD
    output, status = run_gate(tmpdir, {
                                '.leakcheck-allow' => allowlist,
                                'CHANGELOG.md' => changelog
                              })

    expect(status.exitstatus).to eq(0), "expected frozen history exempt; got:\n#{output}"
  end

  it 'fails on an allowlist entry without a justification comment' do
    output, status = run_gate(tmpdir, {
                                '.leakcheck-allow' => "#{allowlist}README.md\n",
                                'README.md' => "A clean readme.\n"
                              })

    expect(status.exitstatus).to eq(1)
    expect(output).to include("needs a trailing '# justification' comment")
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
# rubocop:enable RSpec/ExampleLength
