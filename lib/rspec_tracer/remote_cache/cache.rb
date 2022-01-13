# frozen_string_literal: true

require_relative 'aws'
require_relative 'repo'
require_relative 'validator'

module RSpecTracer
  module RemoteCache
    class Cache
      class CacheError < StandardError; end

      def initialize
        @aws = RSpecTracer::RemoteCache::Aws.new
        @repo = RSpecTracer::RemoteCache::Repo.new(@aws)
      end

      def download
        return unless cache_ref?

        @aws.download_file(@cache_sha, 'last_run.json')
        @aws.download_dir(@cache_sha, last_run_id)
      end

      def upload
        @aws.upload_file(@repo.branch_ref, 'last_run.json')
        @aws.upload_dir(@repo.branch_ref, last_run_id)

        file_name = File.join(RSpecTracer.cache_path, 'branch_refs.json')

        write_branch_refs(file_name)
        @aws.upload_branch_refs(@repo.branch_name, file_name)
      end

      private

      def cache_ref?
        cache_validator = RSpecTracer::RemoteCache::Validator.new

        @cache_sha = @repo.cache_refs.each_key.detect do |ref|
          RSpecTracer.logger.debug "Validating ref #{ref}"

          cache_validator.valid?(ref, @aws.cache_files_list(ref))
        end

        if @cache_sha.nil?
          RSpecTracer.logger.warn 'Could not find a suitable cache sha to download'

          return false
        end

        true
      end

      def write_branch_refs(file_name)
        branch_ref_time = `git show --no-patch --format="%ct" #{@repo.branch_ref}`.chomp

        unless $CHILD_STATUS.success?
          RSpecTracer.logger.warn "Failed to find object #{@repo.branch_ref} commit timestamp"
        end

        ref_list = @repo.branch_refs.merge(@repo.branch_ref => branch_ref_time.to_i)

        File.write(file_name, JSON.pretty_generate(ref_list))
      end

      def last_run_id
        file_name = File.join(RSpecTracer.cache_path, 'last_run.json')

        raise CacheError, 'Could not find any local cache to upload' unless File.file?(file_name)

        JSON.parse(File.read(file_name))['run_id']
      end
    end
  end
end
