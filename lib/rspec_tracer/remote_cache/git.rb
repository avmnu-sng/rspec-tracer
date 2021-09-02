# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    class Git
      class GitOperationError < StandardError; end

      attr_reader :branch_ref, :ref_list

      def initialize
        fetch_head_ref
        fetch_branch_ref
      end

      def prepare_for_download
        fetch_unreachable_refs
        fetch_ancestry_refs
        fetch_ordered_refs
      end

      private

      def fetch_head_ref
        @head_ref = `git rev-parse HEAD`.chomp

        raise GitOperationError, 'Could not find HEAD commit sha' unless $CHILD_STATUS.success?
      end

      def fetch_branch_ref
        @merged_parents = []
        @ignored_refs = []

        unless merged?
          @branch_ref = @head_ref

          return
        end

        @ignored_refs << @head_ref

        fetch_merged_parents
        fetch_merged_branch_ref
      end

      def merged?
        system('git', 'rev-parse', 'HEAD^2', out: File::NULL, err: File::NULL)
      end

      def fetch_merged_parents
        first_parent = `git rev-parse HEAD^1`.chomp
        @merged_parents << first_parent if $CHILD_STATUS.success?

        second_parent = `git rev-parse HEAD^2`.chomp
        @merged_parents << second_parent if $CHILD_STATUS.success?

        raise GitOperationError, 'Could not find merged commit parents' if @merged_parents.length != 2
      end

      def fetch_merged_branch_ref
        @origin_head_ref = `git rev-parse origin/HEAD`.chomp
        @branch_ref = nil

        if @merged_parents.first != @origin_head_ref
          @branch_ref = @head_ref
          @ignored_refs = []

          return
        end

        @branch_ref = @merged_parents.last
        @ignored_refs = @ignored_refs.to_set | `git rev-list #{@branch_ref}..origin/HEAD`.chomp.split

        raise GitOperationError, 'Could not find ignored refs' unless $CHILD_STATUS.success?
      end

      def fetch_unreachable_refs
        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          git fsck
              --no-progress
              --unreachable
              --connectivity-only #{@branch_ref}
            | awk '/commit/ { print $3 }'
            | head -n 25
        COMMAND

        @unreachable_refs = `#{command}`.chomp.split

        raise GitOperationError, 'Could not find unreachable refs' unless $CHILD_STATUS.success?
      end

      def fetch_ancestry_refs
        @ancestry_refs = `git rev-list --max-count=25 #{@branch_ref}`.chomp.split

        raise GitOperationError, 'Could not find ancestry refs' unless $CHILD_STATUS.success?
      end

      def fetch_ordered_refs
        unordered_refs = (@unreachable_refs.to_set | @ancestry_refs) - @ignored_refs

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          git rev-list
            --topo-order
            --no-walk=sorted
            #{unordered_refs.to_a.join(' ')}
        COMMAND

        @ref_list = `#{command}`.chomp.split

        raise GitOperationError, 'Could not find refs to download cache' unless $CHILD_STATUS.success?
      end
    end
  end
end
