# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# M8.10: rspec-tracer in a non-git directory (graceful degradation).
#
# Real-world scenarios where this happens:
#   - User runs rspec in a tarball-extracted source dir.
#   - User invokes from a Docker context that copied code without
#     `.git/`.
#   - User starts a fresh project with `bundle init` + a few specs
#     before running `git init`.
#
# The engine's main code path does NOT depend on git — only the
# remote-cache surface (UserTasks + GitAncestry) does. So a non-git
# invocation should:
#
#   1. Run rspec to completion without crashing.
#   2. Write the canonical cache + reports.
#   3. NOT shell out to `git` from any non-remote-cache code path
#      (boot, tracker, filter, reporters).
#
# Drives a subprocess inside `Bundler.with_unbundled_env` + a tmpdir
# CWD to ensure no `.git/` is reachable from the project root or any
# parent directory; verifies the run produces a usable cache.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'rspec-tracer in a non-git working directory (M8.10)' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  let(:inline_spec_body) do
    <<~RUBY
      require "rspec_tracer"
      RSpecTracer.start

      RSpec.describe "non-git invocation" do
        it "runs to completion without crashing on missing git history" do
          expect(true).to be(true)
        end

        it "exercises a second example for cache + dependency tracking" do
          expect(2 + 2).to eq(4)
        end
      end
    RUBY
  end

  it 'runs rspec to completion + writes a usable cache without a .git/ directory present' do
    Dir.mktmpdir do |dir|
      # Verify no .git/ reachable from the run dir or any ancestor we
      # might walk through. Dir.mktmpdir defaults to /tmp/* (or
      # /var/folders/* on macOS); the chosen dir is git-detached.
      expect(File.directory?(File.join(dir, '.git'))).to be(false)

      spec_path = File.join(dir, 'non_git_smoke_spec.rb')
      File.write(spec_path, inline_spec_body)

      out, status = Bundler.with_unbundled_env do
        env = {
          'BUNDLE_GEMFILE' => gemfile_path,
          # No GIT_DEFAULT_BRANCH / GIT_BRANCH set: covers the
          # "user just runs rspec in a scratch dir" case where
          # remote_cache is not configured and the engine should
          # never try to shell out to git on its own.
          'GIT_DEFAULT_BRANCH' => nil,
          'GIT_BRANCH' => nil
        }
        Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', spec_path,
                        chdir: dir)
      end

      expect(status.success?).to(
        be(true),
        "rspec subprocess in non-git dir failed (exit=#{status.exitstatus}):\n#{out}"
      )

      cache_dir = File.join(dir, 'rspec_tracer_cache')
      manifest_path = File.join(cache_dir, 'last_run.json')
      expect(File).to(
        exist(manifest_path),
        "expected rspec-tracer cache manifest at #{manifest_path}; got: " \
        "#{Dir.exist?(cache_dir) ? Dir.children(cache_dir).inspect : '(no cache dir)'}"
      )

      manifest = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))
      run_id = manifest.fetch('run_id')
      all_examples = JSON.parse(File.read(File.join(cache_dir, run_id, 'all_examples.json'), encoding: 'UTF-8'))
      expect(all_examples.size).to eq(2)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
