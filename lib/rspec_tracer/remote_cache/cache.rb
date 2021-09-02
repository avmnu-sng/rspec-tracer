# frozen_string_literal: true

require_relative 'git'

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
        @test_suite_id = ENV['TEST_SUITE_ID'].to_s
        @test_suites = ENV.fetch('TEST_SUITES', '1').to_i
        @total_objects = CACHE_FILES_PER_TEST_SUITE * @test_suites
      end

      def download
        if @s3_uri.nil?
          puts 'S3 URI is not configured'

          return
        end

        @git = RSpecTracer::RemoteCache::Git.new
        @git.prepare_for_download

        @cache_sha = nearest_cache_sha

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

        @run_id = last_run_id
        @git = RSpecTracer::RemoteCache::Git.new

        upload_files

        puts "Uploaded cache from #{@upload_path} to #{@upload_prefix}"
      rescue CacheUploadError => e
        puts "Errored: #{e.message}"
      end

      private

      def nearest_cache_sha
        @git.ref_list.detect do |ref|
          prefix = "#{@s3_uri}/#{ref}/#{@test_suite_id}/".sub(%r{/+$}, '/')

          puts "Testing prefix #{prefix}"

          command = <<-COMMAND.strip.gsub(/\s+/, ' ')
            #{@aws_s3} s3 ls #{prefix}
              --recursive
              --summarize
            | grep 'Total Objects'
          COMMAND

          @total_objects == `#{command}`.chomp.split('Total Objects:').last.to_s.strip.to_i
        end
      end

      def download_files
        @download_prefix = "#{@s3_uri}/#{@cache_sha}/#{@test_suite_id}/".sub(%r{/+$}, '/')
        @download_path = RSpecTracer.cache_path

        return if system(
          @aws_s3, 's3', 'cp',
          @download_prefix,
          @download_path,
          '--recursive',
          out: File::NULL, err: File::NULL
        )

        FileUtils.rm_rf(@download_path)

        raise CacheDownloadError, 'Failed to download cache files'
      end

      def last_run_id
        file_name = File.join(RSpecTracer.cache_path, 'last_run.json')

        return unless File.file?(file_name)

        run_id = JSON.parse(File.read(file_name))['run_id']

        raise LocalCacheNotFoundError, 'Could not find any local cache to upload' if run_id.nil?

        run_id
      end

      def upload_files
        @upload_prefix = "#{@s3_uri}/#{@git.branch_ref}/#{@test_suite_id}/".sub(%r{/+$}, '/')
        @upload_path = RSpecTracer.cache_path

        return if system(
          @aws_s3, 's3', 'cp',
          File.join(@upload_path, 'last_run.json'),
          @upload_prefix,
          out: File::NULL, err: File::NULL
        ) && system(
          @aws_s3, 's3', 'cp',
          File.join(@upload_path, @run_id),
          "#{@upload_prefix}/#{@run_id}",
          '--recursive',
          out: File::NULL, err: File::NULL
        )

        raise CacheUploadError, 'Failed to upload cache files'
      end
    end
  end
end
