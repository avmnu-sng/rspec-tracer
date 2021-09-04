# frozen_string_literal: true

require_relative 'git'
require 'msgpack'

module RSpecTracer
  module RemoteCache
    class Cache
      class CacheDownloadError < StandardError; end

      class CacheUploadError < StandardError; end

      class LocalCacheNotFoundError < StandardError; end

      CACHE_FILES_PER_TEST_SUITE = 8

      def initialize
        @s3_uri = ENV['RSPEC_TRACER_S3_URI']
        @aws_s3 = if ENV.fetch('LOCAL_AWS', 'false') == 'true'
                    'awslocal'
                  else
                    'aws'
                  end
      end

      def download
        if @s3_uri.nil?
          puts 'S3 URI is not configured'

          return
        end

        prepare_for_download

        if @cache_sha.nil?
          puts 'Could not find a suitable cache sha to download'

          return
        end

        download_files

        puts "Downloaded cache from #{@download_prefix} to #{@download_path}"
      rescue StandardError => e
        puts "Errored: #{e.message}"
      end

      def upload
        if @s3_uri.nil?
          puts 'S3 URI is not configured'

          return
        end

        prepare_for_upload
        upload_files

        puts "Uploaded cache from #{@upload_path} to #{@upload_prefix}"
      rescue CacheUploadError => e
        puts "Errored: #{e.message}"
      end

      private

      def prepare_for_download
        @test_suite_id = ENV['TEST_SUITE_ID']
        @test_suites = ENV['TEST_SUITES']

        if @test_suite_id.nil? ^ @test_suites.nil?
          raise(
            CacheDownloadError,
            'Both the enviornment variables TEST_SUITE_ID and TEST_SUITES are not set'
          )
        end

        @git = RSpecTracer::RemoteCache::Git.new
        @git.prepare_for_download

        generate_cached_files_count_and_regex

        @cache_sha = nearest_cache_sha
      end

      def generate_cached_files_count_and_regex
        if @test_suites.nil?
          @last_run_files_count = 1
          @last_run_files_regex = '/%<ref>s/last_run.json$'
          @cached_files_count = CACHE_FILES_PER_TEST_SUITE
          @cached_files_regex = '/%<ref>s/[0-9a-f]{32}/.+.json'
        else
          @test_suites = @test_suites.to_i
          @test_suites_regex = (1..@test_suites).to_a.join('|')

          @last_run_files_count = @test_suites
          @last_run_files_regex = "/%<ref>s/(#{@test_suites_regex})/last_run.json$"
          @cached_files_count = CACHE_FILES_PER_TEST_SUITE * @test_suites.to_i
          @cached_files_regex = "/%<ref>s/(#{@test_suites_regex})/[0-9a-f]{32}/.+.json$"
        end
      end

      def nearest_cache_sha
        @git.ref_list.detect do |ref|
          prefix = "#{@s3_uri}/#{ref}/"

          puts "Testing prefix #{prefix}"

          objects = `#{@aws_s3} s3 ls #{prefix} --recursive`.chomp.split("\n")

          last_run_regex = Regexp.new(format(@last_run_files_regex, ref: ref))

          next if objects.count { |object| object.match?(last_run_regex) } != @last_run_files_count

          cache_regex = Regexp.new(format(@cached_files_regex, ref: ref))

          objects.count { |object| object.match?(cache_regex) } == @cached_files_count
        end
      end

      def download_files
        @download_prefix = "#{@s3_uri}/#{@cache_sha}/#{@test_suite_id}/".sub(%r{/+$}, '/')
        @download_path = RSpecTracer.cache_path

        raise CacheDownloadError, 'Failed to download cache files' unless system(
          @aws_s3, 's3', 'cp',
          File.join(@download_prefix, 'last_run.json'),
          @download_path,
          out: File::NULL, err: File::NULL
        )

        @run_id = last_run_id

        return if system(
          @aws_s3, 's3', 'cp',
          File.join(@download_prefix, @run_id),
          File.join(@download_path, @run_id),
          '--recursive',
          out: File::NULL, err: File::NULL
        )

        FileUtils.rm_rf(@download_path)

        raise CacheDownloadError, 'Failed to download cache files'
      end

      def prepare_for_upload
        @git = RSpecTracer::RemoteCache::Git.new
        @test_suite_id = ENV['TEST_SUITE_ID']
        @upload_prefix = if @test_suite_id.nil?
                           "#{@s3_uri}/#{@git.branch_ref}/"
                         else
                           "#{@s3_uri}/#{@git.branch_ref}/#{@test_suite_id}/"
                         end

        @upload_path = RSpecTracer.cache_path
        @run_id = last_run_id
      end

      def upload_files
        return if system(
          @aws_s3, 's3', 'cp',
          File.join(@upload_path, 'last_run.json'),
          @upload_prefix,
          out: File::NULL, err: File::NULL
        ) && system(
          @aws_s3, 's3', 'cp',
          File.join(@upload_path, @run_id),
          File.join(@upload_prefix, @run_id),
          '--recursive',
          out: File::NULL, err: File::NULL
        )

        raise CacheUploadError, 'Failed to upload cache files'
      end

      def last_run_id
        file_name = File.join(RSpecTracer.cache_path, 'last_run.json')

        return unless File.file?(file_name)

        run_id = RSpecTracer.cache_serializer.deserialize(File.read(file_name))['run_id']

        raise LocalCacheNotFoundError, 'Could not find any local cache to upload' if run_id.nil?

        run_id
      end
    end
  end
end
