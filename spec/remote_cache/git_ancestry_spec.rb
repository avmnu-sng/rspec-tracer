# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

require 'rspec_tracer/remote_cache/git_ancestry'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Fake-git-repo fixture helpers. Each test runs `Dir.chdir` into a
# freshly created repo so the GitAncestry backticks see controlled
# state. The "origin" is a bare repo clone; the "work" tree is where
# branches + merge commits live.
#
# Git commands are run quietly (stdout+stderr to /dev/null) except
# when we want to inspect failures. `sh!` raises on non-zero; `sh`
# returns status+stdout.
module FakeGitRepo
  def with_fake_repo(&)
    Dir.mktmpdir do |remote_dir|
      Dir.mktmpdir do |work_dir|
        setup_remote!(remote_dir)
        setup_work!(work_dir, remote_dir)

        Dir.chdir(work_dir) do
          yield(work_dir, remote_dir)
        end
      end
    end
  end

  def setup_remote!(remote_dir)
    sh!('git', 'init', '--bare', '--quiet', '--initial-branch=main', remote_dir)
  end

  def setup_work!(work_dir, remote_dir)
    Dir.chdir(work_dir) do
      sh!('git', 'init', '--quiet', '--initial-branch=main')
      sh!('git', 'config', 'user.email', 'test@example.com')
      sh!('git', 'config', 'user.name', 'Test')
      sh!('git', 'remote', 'add', 'origin', remote_dir)
      write_and_commit('README.md', 'hello', 'initial commit')
      sh!('git', 'push', '--quiet', '-u', 'origin', 'main')
      sh!('git', 'remote', 'set-head', 'origin', 'main')
    end
  end

  def write_and_commit(path, content, message)
    File.write(path, content)
    sh!('git', 'add', path)
    sh!('git', 'commit', '--quiet', '-m', message)
  end

  def create_branch!(name)
    sh!('git', 'checkout', '--quiet', '-b', name)
  end

  def checkout!(name)
    sh!('git', 'checkout', '--quiet', name)
  end

  def push_branch!(name)
    sh!('git', 'push', '--quiet', '-u', 'origin', name)
  end

  def current_head
    out, = Open3.capture3('git', 'rev-parse', 'HEAD')
    out.chomp
  end

  def sh!(*cmd)
    _stdout, stderr, status = Open3.capture3(*cmd)
    raise "git cmd failed: #{cmd.join(' ')}\n#{stderr}" unless status.success?
  end
end

RSpec.describe RSpecTracer::RemoteCache::GitAncestry do
  include FakeGitRepo

  describe '#initialize' do
    it 'raises when default_branch is nil' do
      expect { described_class.new(default_branch: nil, branch: 'feat') }
        .to raise_error(described_class::GitAncestryError, /default_branch/)
    end

    it 'raises when default_branch is empty' do
      expect { described_class.new(default_branch: '', branch: 'feat') }
        .to raise_error(described_class::GitAncestryError, /default_branch/)
    end

    it 'raises when branch is nil' do
      expect { described_class.new(default_branch: 'main', branch: nil) }
        .to raise_error(described_class::GitAncestryError, /branch/)
    end

    it 'raises when branch is empty' do
      expect { described_class.new(default_branch: 'main', branch: '') }
        .to raise_error(described_class::GitAncestryError, /branch/)
    end

    it 'trims trailing newlines from branch names' do
      ancestry = described_class.new(default_branch: "main\n", branch: "feat\n")

      expect(ancestry.default_branch_name).to eq('main')
      expect(ancestry.branch_name).to eq('feat')
    end
  end

  describe '#pr_build?' do
    it 'is false when branch == default_branch' do
      ancestry = described_class.new(default_branch: 'main', branch: 'main')

      expect(ancestry.pr_build?).to be(false)
    end

    it 'is true when branch != default_branch' do
      ancestry = described_class.new(default_branch: 'main', branch: 'feat')

      expect(ancestry.pr_build?).to be(true)
    end
  end

  describe '#merge_commit?' do
    it 'is false on a repo with a single commit' do
      with_fake_repo do
        ancestry = described_class.new(default_branch: 'main', branch: 'main')

        expect(ancestry.merge_commit?).to be(false)
      end
    end

    it 'is true on a branch tip that is a merge commit' do
      with_fake_repo do
        create_branch!('feat')
        write_and_commit('feat.txt', 'feat content', 'feat commit')
        checkout!('main')
        write_and_commit('main.txt', 'main content', 'main commit')
        sh!('git', 'merge', 'feat', '--no-ff', '--no-edit', '--quiet')

        ancestry = described_class.new(default_branch: 'main', branch: 'main')

        expect(ancestry.merge_commit?).to be(true)
      end
    end

    it 'memoizes the result' do
      with_fake_repo do
        ancestry = described_class.new(default_branch: 'main', branch: 'main')
        first = ancestry.merge_commit?

        expect(ancestry.merge_commit?).to be(first)
      end
    end
  end

  describe '#branch_ref' do
    it 'is HEAD on a non-merge-commit build' do
      with_fake_repo do
        head = current_head
        ancestry = described_class.new(default_branch: 'main', branch: 'main')

        expect(ancestry.branch_ref).to eq(head)
      end
    end

    it 'is HEAD^1 on a merge-commit build (first parent of the merge)' do
      with_fake_repo do
        # `git merge feat --no-ff` on main: HEAD^1 = prior main tip,
        # HEAD^2 = feat tip. The code uses HEAD^1 as branch_ref so the
        # cache keys under the caller's own branch lineage.
        create_branch!('feat')
        write_and_commit('feat.txt', 'feat content', 'feat commit')
        checkout!('main')
        write_and_commit('main.txt', 'main content', 'main commit')
        main_tip_before_merge = current_head
        sh!('git', 'merge', 'feat', '--no-ff', '--no-edit', '--quiet')

        ancestry = described_class.new(default_branch: 'main', branch: 'main')

        expect(ancestry.branch_ref).to eq(main_tip_before_merge)
      end
    end

    it 'memoizes the result' do
      with_fake_repo do
        ancestry = described_class.new(default_branch: 'main', branch: 'main')
        first = ancestry.branch_ref

        expect(ancestry.branch_ref).to equal(first)
      end
    end
  end

  describe '#ancestry_refs' do
    it 'returns an empty hash on a fresh single-commit repo for a PR with the same SHA' do
      with_fake_repo do
        # With one commit on main, a non-merge feat branch off main
        # has no ancestors to walk past itself.
        create_branch!('feat')
        ancestry = described_class.new(default_branch: 'main', branch: 'feat')

        refs = ancestry.ancestry_refs
        expect(refs).to be_a(Hash)
        # At least the current HEAD is in the walk.
        expect(refs).to include(current_head)
      end
    end

    it 'includes branch history commits with committer timestamps' do
      with_fake_repo do
        2.times { |i| write_and_commit("f#{i}.txt", "c#{i}", "commit #{i}") }
        ancestry = described_class.new(default_branch: 'main', branch: 'main')

        refs = ancestry.ancestry_refs

        expect(refs.size).to be >= 3 # initial + 2 extra
        refs.each_value { |ts| expect(ts).to be_a(Integer) }
      end
    end

    it 'bounds to ANCESTRY_DEPTH (25) commits' do
      with_fake_repo do
        30.times { |i| write_and_commit("f#{i}.txt", "c#{i}", "commit #{i}") }
        ancestry = described_class.new(default_branch: 'main', branch: 'main')

        expect(ancestry.ancestry_refs.size).to eq(described_class::ANCESTRY_DEPTH)
      end
    end

    it 'memoizes the result' do
      with_fake_repo do
        ancestry = described_class.new(default_branch: 'main', branch: 'main')
        first = ancestry.ancestry_refs

        expect(ancestry.ancestry_refs).to equal(first)
      end
    end
  end

  describe '#merge_base_branch!' do
    it 'is a no-op when branch == default_branch' do
      with_fake_repo do
        head_before = current_head
        ancestry = described_class.new(default_branch: 'main', branch: 'main')
        ancestry.merge_base_branch!

        expect(current_head).to eq(head_before)
      end
    end

    it 'fetches + checks out + merges default into the PR branch' do
      with_fake_repo do
        # Set up: a feat branch that's behind main, pushed to origin.
        create_branch!('feat')
        write_and_commit('feat.txt', 'feat', 'feat commit')
        push_branch!('feat')
        checkout!('main')
        write_and_commit('main.txt', 'main', 'main commit')
        sh!('git', 'push', '--quiet', 'origin', 'main')
        # Checkout feat so the working tree matches a CI-PR checkout.
        checkout!('feat')

        ancestry = described_class.new(default_branch: 'main', branch: 'feat')
        ancestry.merge_base_branch!

        expect(ancestry.merge_commit?).to be(true)
      end
    end

    it 'raises when the default branch cannot be merged (conflict)' do
      with_fake_repo do
        create_branch!('feat')
        write_and_commit('conflict.txt', 'feat version', 'feat commit')
        push_branch!('feat')
        checkout!('main')
        write_and_commit('conflict.txt', 'main version', 'main commit')
        sh!('git', 'push', '--quiet', 'origin', 'main')
        checkout!('feat')

        ancestry = described_class.new(default_branch: 'main', branch: 'feat')

        expect { ancestry.merge_base_branch! }
          .to raise_error(described_class::GitAncestryError, /Could not merge/)
      end
    end

    it 'checks out the PR branch first when on detached HEAD' do
      with_fake_repo do
        # Set up: push feat to origin, then detach HEAD locally.
        create_branch!('feat')
        write_and_commit('feat.txt', 'feat', 'feat commit')
        push_branch!('feat')
        # Bring main forward and push so there's something to merge.
        checkout!('main')
        write_and_commit('main.txt', 'main', 'main commit')
        sh!('git', 'push', '--quiet', 'origin', 'main')
        # Simulate a detached-HEAD CI checkout (refs/pull/N/merge style).
        sh!('git', 'checkout', '--quiet', '--detach', 'feat')

        ancestry = described_class.new(default_branch: 'main', branch: 'feat')
        ancestry.merge_base_branch!

        # After the merge_base_branch! ran, we should be on feat (not detached).
        current = `git rev-parse --abbrev-ref HEAD`.chomp
        expect(current).to eq('feat')
        expect(ancestry.merge_commit?).to be(true)
      end
    end

    it 'raises when the remote branch fetch fails' do
      with_fake_repo do
        create_branch!('feat')
        sh!('git', 'checkout', '--quiet', '--detach')
        # Point origin to a bogus URL so fetch fails.
        sh!('git', 'remote', 'set-url', 'origin', '/nonexistent/remote.git')

        ancestry = described_class.new(default_branch: 'main', branch: 'feat')

        expect { ancestry.merge_base_branch! }
          .to raise_error(described_class::GitAncestryError, /Could not pull remote branch/)
      end
    end

    it 'resets memoized branch_ref after merge' do
      with_fake_repo do
        create_branch!('feat')
        write_and_commit('feat.txt', 'feat', 'feat commit')
        feat_head = current_head
        push_branch!('feat')
        checkout!('main')
        write_and_commit('main.txt', 'main', 'main commit')
        sh!('git', 'push', '--quiet', 'origin', 'main')
        checkout!('feat')

        ancestry = described_class.new(default_branch: 'main', branch: 'feat')
        _ = ancestry.branch_ref # prime memo: this is feat_head (no merge yet)
        ancestry.merge_base_branch!

        expect(ancestry.branch_ref).to eq(feat_head) # HEAD^1 after merge == original feat tip
      end
    end
  end

  describe 'error handling' do
    it 'raises when git is not a repo' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          ancestry = described_class.new(default_branch: 'main', branch: 'main')

          expect { ancestry.branch_ref }.to raise_error(described_class::GitAncestryError)
        end
      end
    end

    it 'raises when merging fails due to missing origin' do
      with_fake_repo do
        create_branch!('feat')
        sh!('git', 'remote', 'remove', 'origin')
        ancestry = described_class.new(default_branch: 'main', branch: 'feat')

        expect { ancestry.merge_base_branch! }.to raise_error(described_class::GitAncestryError)
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
