# frozen_string_literal: true

require 'English'
require 'set'

module RSpecTracer
  # Internal RemoteCache — see {RSpecTracer} for the user-facing surface.
  # @api private
  module RemoteCache
    # Git ancestry walker. Given the current branch + default branch,
    # answers "which commit should I upload cache under?" and "which
    # prior commits should I try as cache candidates?"
    #
    # Behavior preserved verbatim from 1.x `RemoteCache::Repo` -
    # USER_FACING_SURFACE.md pins the 25-commit ancestry, branch_refs,
    # history-rewrite resilience, merge-commit handling, and shallow-
    # clone guidance as user contracts. Any change here affects every
    # existing CI config that sets `fetch-depth: 25` or relies on the
    # current "nearest ancestor" heuristic.
    #
    # Four scenarios this class handles:
    #
    #   1. Main branch build (GIT_BRANCH == GIT_DEFAULT_BRANCH):
    #      merge_base_branch! is a no-op. branch_ref = HEAD (or HEAD^1
    #      if HEAD is itself a merge commit, e.g. main just absorbed a
    #      feature branch via --no-ff merge). Ancestry walks HEAD^'s
    #      linear history up to 25 commits.
    #
    #   2. GitHub Actions PR (checkout of refs/pull/N/merge, detached
    #      HEAD on a synthetic merge commit):
    #      merge_base_branch! runs `git fetch origin <branch>:<branch>`
    #      + `git checkout <branch>` + `git merge origin/<default>
    #      --no-edit --no-ff`. After this HEAD is a (possibly new) merge
    #      commit. branch_ref = HEAD^1 (the PR branch tip). Ancestry
    #      walks HEAD^1's 25-commit history UNION `HEAD^1..origin/HEAD`
    #      (default branch commits the PR hasn't absorbed yet).
    #
    #   3. Jenkins / CircleCI / Travis PR (checkout of raw PR branch):
    #      merge_base_branch! materializes the merge commit that GHA
    #      provides automatically. Result is identical to scenario 2.
    #
    #   4. PR branch behind main: same flow as 2/3. The explicit merge
    #      ensures RSpec runs against the merged state and ancestry
    #      picks up main's recent commits as candidates.
    #
    # The merge is a WORKING-TREE MUTATION. Callers should run
    # `merge_base_branch!` exactly once at the start of each Rake task
    # invocation (download + upload each instantiate a fresh orchestrator
    # and re-run the merge; idempotent on a clean tree). See
    # RSPEC_TRACER.md "Caching on CI" for the user-facing rationale.
    class GitAncestry
      # Internal GitAncestryError — see {RSpecTracer} for the user-facing surface.
      # @api private
      class GitAncestryError < StandardError; end

      # Matches 1.x. 25 commits is a 14-year-stable tradeoff between
      # cache hit rate on slow trunks and ancestry-walk cost.
      ANCESTRY_DEPTH = 25

      # Internal attribute.
      # @api private
      attr_reader :default_branch_name, :branch_name

      # Internal method on the tracer pipeline.
      # @api private
      def initialize(default_branch:, branch:)
        raise GitAncestryError, 'default_branch is required' if default_branch.nil? || default_branch.to_s.empty?
        raise GitAncestryError, 'branch is required' if branch.nil? || branch.to_s.empty?

        @default_branch_name = default_branch.to_s.chomp
        @branch_name = branch.to_s.chomp
      end

      # True when this is a PR build (current branch != default branch).
      def pr_build?
        @branch_name != @default_branch_name
      end

      # True when HEAD has two parents (i.e., a merge commit). Cached.
      def merge_commit?
        return @merge_commit if defined?(@merge_commit)

        @merge_commit = system('git', 'rev-parse', 'HEAD^2', out: File::NULL, err: File::NULL)
      end

      # Materialize the PR-merged state: fetch + checkout + merge default.
      # No-op on main builds. Idempotent on a clean tree (a subsequent
      # `git merge origin/<default>` when already merged produces "Already
      # up to date", no new merge commit).
      #
      # Raises GitAncestryError on fetch/checkout/merge failure. The
      # orchestrator catches and logs; the user's Rake task exits
      # cleanly with a warning but proceeds to cold-run.
      def merge_base_branch!
        return if @default_branch_name == @branch_name

        pull_remote_branch! if current_branch != @branch_name
        merge_default_branch!
        reset_memo!
      end

      # The SHA to upload cache under, and to seed ancestry walk from.
      # When HEAD is a merge commit (normal PR case after merge_base_branch!
      # runs), branch_ref = HEAD^1 (the real branch tip). Uploading under
      # HEAD directly would key the cache under a synthetic merge SHA
      # that no future build's ancestry walk can reach.
      def branch_ref
        return @branch_ref if defined?(@branch_ref)

        head = head_ref
        if merge_commit?
          parents = merged_parents
          @branch_ref = parents.first
          @ignored_refs = [head]
        else
          @branch_ref = head
          @ignored_refs = []
        end
        @branch_ref
      end

      # Hash{sha => committer_timestamp} of candidate ancestor commits.
      # Newest-first ordering is applied by the orchestrator when merging
      # with branch_refs; this method returns insertion order.
      #
      # Walk rule:
      #   refs = Set[]
      #   if merge_commit?: refs |= rev-list --max-count=25 branch_ref..origin/HEAD
      #   refs |= rev-list --max-count=25 branch_ref
      #   refs -= ignored_refs  # drop synthetic HEAD when merged
      #
      # Returns {} when the walk yields nothing (new repo, shallow
      # clone shorter than 25, etc.). Not an error.
      def ancestry_refs
        return @ancestry_refs if defined?(@ancestry_refs)

        branch_ref # materialize ignored_refs

        ref_list = Set.new
        ref_list |= rev_list("#{@branch_ref}..origin/HEAD") if merge_commit?
        ref_list |= rev_list(@branch_ref.to_s)

        @ancestry_refs = refs_committer_timestamp(ref_list - @ignored_refs)
      end

      private

      # Internal method on the tracer pipeline.
      # @api private
      def reset_memo!
        remove_instance_variable(:@merge_commit) if defined?(@merge_commit)
        remove_instance_variable(:@branch_ref) if defined?(@branch_ref)
        remove_instance_variable(:@ignored_refs) if defined?(@ignored_refs)
        remove_instance_variable(:@ancestry_refs) if defined?(@ancestry_refs)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def current_branch
        branch = `git rev-parse --abbrev-ref HEAD`.chomp
        raise GitAncestryError, 'Could not determine current branch' unless $CHILD_STATUS.success?

        branch
      end

      # Internal method on the tracer pipeline.
      # @api private
      def pull_remote_branch!
        fetched = system(
          'git', 'fetch', 'origin', "#{@branch_name}:#{@branch_name}",
          out: File::NULL, err: File::NULL
        )
        checked_out = fetched && system(
          'git', 'checkout', @branch_name,
          out: File::NULL, err: File::NULL
        )
        raise GitAncestryError, "Could not pull remote branch #{@branch_name}" unless checked_out
      end

      # Internal method on the tracer pipeline.
      # @api private
      def merge_default_branch!
        merged = system(
          'git', 'merge', "origin/#{@default_branch_name}",
          '--no-edit', '--no-ff',
          out: File::NULL, err: File::NULL
        )
        raise GitAncestryError, "Could not merge #{@default_branch_name} into #{@branch_name}" unless merged
      end

      # Internal method on the tracer pipeline.
      # @api private
      def head_ref
        head = `git rev-parse HEAD`.chomp
        raise GitAncestryError, 'Could not find HEAD commit sha' unless $CHILD_STATUS.success?

        head
      end

      # Internal method on the tracer pipeline.
      # @api private
      def merged_parents
        parents = []
        first_parent = `git rev-parse HEAD^1`.chomp
        parents << first_parent if $CHILD_STATUS.success?
        second_parent = `git rev-parse HEAD^2`.chomp
        parents << second_parent if $CHILD_STATUS.success?
        raise GitAncestryError, 'Could not find merge commit parents' if parents.length != 2

        parents
      end

      # Internal method on the tracer pipeline.
      # @api private
      def rev_list(spec)
        output = `git rev-list --max-count=#{ANCESTRY_DEPTH} #{spec}`.chomp
        raise GitAncestryError, "Could not list revs for #{spec}" unless $CHILD_STATUS.success?

        output.split
      end

      # Internal method on the tracer pipeline.
      # @api private
      def refs_committer_timestamp(ref_list)
        return {} if ref_list.empty?

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          git show
            --no-patch
            --format="%H %ct"
            #{ref_list.to_a.join(' ')}
        COMMAND

        output = `#{command}`.chomp
        raise GitAncestryError, 'Could not fetch committer timestamps' unless $CHILD_STATUS.success?

        output.split("\n").to_h(&:split).transform_values(&:to_i)
      end
    end
  end
end
