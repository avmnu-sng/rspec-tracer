# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    class Repo
      class RepoError < StandardError; end

      attr_reader :branch_name, :branch_ref, :branch_refs, :ancestry_refs, :cache_refs

      def initialize(aws)
        @aws = aws
        @branch_name = ENV['GIT_BRANCH'].chomp

        raise RepoError, 'GIT_BRANCH environment variable is not set' if @branch_name.nil?

        fetch_head_ref
        fetch_branch_ref
        fetch_ancestry_refs
        fetch_branch_refs
        generate_cache_refs
      end

      private

      def fetch_head_ref
        @head_ref = `git rev-parse HEAD`.chomp

        raise RepoError, 'Could not find HEAD commit sha' unless $CHILD_STATUS.success?
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

      def fetch_ancestry_refs
        ref_list = `git rev-list --max-count=25 #{@branch_ref}`.chomp.split

        raise RepoError, 'Could not find ancestry refs' unless $CHILD_STATUS.success?

        ref_list = ref_list.to_set - @ignored_refs
        @ancestry_refs = refs_committer_timestamp(ref_list.to_a)

        return if @ancestry_refs.empty?

        print_refs(@ancestry_refs, 'ancestry')
      end

      def fetch_branch_refs
        unless @aws.branch_refs?(@branch_name)
          puts "No branch refs for #{@branch_name} branch found in S3"

          @branch_refs = {}

          return
        end

        download_branch_refs
      end

      def generate_cache_refs
        ref_list = @ancestry_refs.merge(@branch_refs)

        if ref_list.empty?
          @cache_refs = {}

          return
        end

        @cache_refs = ref_list.sort_by { |_, timestamp| -timestamp }.to_h

        print_refs(@cache_refs, 'cache')
      end

      def merged?
        system('git', 'rev-parse', 'HEAD^2', out: File::NULL, err: File::NULL)
      end

      def fetch_merged_parents
        first_parent = `git rev-parse HEAD^1`.chomp
        @merged_parents << first_parent if $CHILD_STATUS.success?

        second_parent = `git rev-parse HEAD^2`.chomp
        @merged_parents << second_parent if $CHILD_STATUS.success?

        raise RepoError, 'Could not find merged commit parents' if @merged_parents.length != 2
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

        raise RepoError, 'Could not find ignored refs' unless $CHILD_STATUS.success?
      end

      def refs_committer_timestamp(ref_list)
        return {} if ref_list.empty?

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          git show
            --no-patch
            --format="%H %ct"
            #{ref_list.join(' ')}
        COMMAND

        ref_list = `#{command}`.chomp

        raise RepoError, 'Could not find ancestry refs' unless $CHILD_STATUS.success?

        ref_list.split("\n").map(&:split).to_h.transform_values(&:to_i)
      end

      def download_branch_refs
        file_name = File.join(RSpecTracer.cache_path, 'branch_refs.json')

        if @aws.download_branch_refs(branch_name, file_name)
          @branch_refs = JSON.parse(File.read(file_name)).transform_values(&:to_i)

          return if @branch_refs.empty?

          filter_branch_refs
          print_refs(@branch_refs, 'branch')
        else
          @branch_refs = {}

          File.rm_f(file_name)

          puts "Failed to fetch branch refs for #{@branch_name} branch"
        end
      end

      def filter_branch_refs
        if @ancestry_refs.empty?
          @branch_refs = @branch_refs.sort_by { |_, timestamp| -timestamp }.first(25).to_h

          return
        end

        oldest_ancestry_time = @ancestry_refs.values.min

        @branch_refs = @branch_refs
          .select { |_, timestamp| timestamp >= oldest_ancestry_time }
          .sort_by { |_, timestamp| -timestamp }
          .first(25)
          .to_h
      end

      def print_refs(refs, type)
        puts "Fetched the following #{type} refs for #{@branch_name} branch:"
        puts refs.map { |ref, timestamp| "  * #{ref} (commit timestamp: #{timestamp})" }.join("\n")
      end
    end
  end
end
