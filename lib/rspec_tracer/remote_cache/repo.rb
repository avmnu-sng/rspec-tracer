# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    class Repo
      class RepoError < StandardError; end

      attr_reader :default_branch_name, :branch_name, :branch_ref, :branch_refs, :ancestry_refs, :cache_refs

      def initialize(aws)
        raise RepoError, 'GIT_DEFAULT_BRANCH environment variable is not set' if ENV['GIT_DEFAULT_BRANCH'].nil?
        raise RepoError, 'GIT_BRANCH environment variable is not set' if ENV['GIT_BRANCH'].nil?

        @aws = aws
        @default_branch_name = ENV['GIT_DEFAULT_BRANCH'].chomp
        @branch_name = ENV['GIT_BRANCH'].chomp

        merge_base_branch
        fetch_head_ref
        fetch_branch_ref
        fetch_ancestry_refs
        fetch_branch_refs
        generate_cache_refs
      end

      private

      def merge_base_branch
        return if @default_branch_name == @branch_name

        pull_remote_branch if current_branch != @branch_name

        merge_default_branch
      end

      def current_branch
        branch = `git rev-parse --abbrev-ref HEAD`.chomp

        return branch if $CHILD_STATUS.success?

        raise RepoError, 'Could not determine current branch'
      end

      def pull_remote_branch
        return if system(
          'git',
          'fetch',
          'origin',
          "#{@branch_name}:#{@branch_name}",
          out: File::NULL,
          err: File::NULL
        ) && system(
          'git',
          'checkout',
          @branch_name,
          out: File::NULL,
          err: File::NULL
        )

        raise RepoError, "Could not pull remote branch #{@branch_name}"
      end

      def merge_default_branch
        return if system(
          'git',
          'merge',
          "origin/#{@default_branch_name}",
          '--no-edit',
          '--no-ff',
          out: File::NULL,
          err: File::NULL
        )

        raise RepoError, "Could not merge #{@default_branch_name} into #{@branch_name}"
      end

      def fetch_head_ref
        @head_ref = `git rev-parse HEAD`.chomp

        raise RepoError, 'Could not find HEAD commit sha' unless $CHILD_STATUS.success?
      end

      def fetch_branch_ref
        if merged?
          fetch_merged_parents

          @branch_ref = @merged_parents.first
          @ignored_refs = [@head_ref]
        else
          @branch_ref = @head_ref
          @ignored_refs = []
        end
      end

      def merged?
        system('git', 'rev-parse', 'HEAD^2', out: File::NULL, err: File::NULL)
      end

      def fetch_merged_parents
        @merged_parents = []

        first_parent = `git rev-parse HEAD^1`.chomp
        @merged_parents << first_parent if $CHILD_STATUS.success?

        second_parent = `git rev-parse HEAD^2`.chomp
        @merged_parents << second_parent if $CHILD_STATUS.success?

        raise RepoError, 'Could not find merge commit parents' if @merged_parents.length != 2
      end

      def fetch_ancestry_refs
        ref_list = Set.new
        ref_list |= `git rev-list --max-count=25 #{@branch_ref}..origin/HEAD`.chomp.split if merged?
        ref_list |= `git rev-list --max-count=25 #{@branch_ref}`.chomp.split

        raise RepoError, 'Could not find ancestry refs' unless $CHILD_STATUS.success?

        @ancestry_refs = refs_committer_timestamp(ref_list - @ignored_refs)

        return if @ancestry_refs.empty?

        print_refs(@ancestry_refs, 'ancestry')
      end

      def fetch_branch_refs
        unless @aws.branch_refs?(@branch_name)
          RSpecTracer.logger.warn "No branch refs for #{@branch_name} branch found in S3"

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

      def refs_committer_timestamp(ref_list)
        return {} if ref_list.empty?

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          git show
            --no-patch
            --format="%H %ct"
            #{ref_list.to_a.join(' ')}
        COMMAND

        ref_timestamp = `#{command}`.chomp

        raise RepoError, 'Could not find ancestry refs' unless $CHILD_STATUS.success?

        ref_timestamp.split("\n").map(&:split).to_h.transform_values(&:to_i)
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

          FileUtils.rm_f(file_name)

          RSpecTracer.logger.error "Failed to fetch branch refs for #{@branch_name} branch"
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
        refs_list = refs.map { |ref, timestamp| "  * #{ref} (commit timestamp: #{timestamp})" }.join("\n")

        RSpecTracer.logger.debug "Fetched the following #{type} refs for #{@branch_name} branch:\n#{refs_list}"
      end
    end
  end
end
