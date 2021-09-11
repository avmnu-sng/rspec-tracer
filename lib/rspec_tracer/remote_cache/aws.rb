# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    class Aws
      class AwsError < StandardError; end

      def initialize
        @s3_bucket, @s3_path = setup_s3
        @aws_cli = setup_aws_cli
      end

      def branch_refs?(branch_name)
        key = "#{@s3_path}/branch-refs/#{branch_name}/branch_refs.json"

        system(
          @aws_cli,
          's3api',
          'head-object',
          '--bucket',
          @s3_bucket,
          '--key',
          key,
          out: File::NULL,
          err: File::NULL
        )
      end

      def download_branch_refs(branch_name, file_name)
        key = "#{@s3_path}/branch-refs/#{branch_name}/branch_refs.json"

        system(
          @aws_cli,
          's3api',
          'get-object',
          '--bucket',
          @s3_bucket,
          '--key',
          key,
          file_name,
          out: File::NULL,
          err: File::NULL
        )
      end

      def upload_branch_refs(branch_name, file_name)
        remote_path = "s3://#{@s3_bucket}/#{@s3_path}/branch-refs/#{branch_name}/branch_refs.json"

        raise AwsError, "Failed to upload branch refs for #{branch_name} branch" unless system(
          @aws_cli,
          's3',
          'cp',
          file_name,
          remote_path,
          out: File::NULL,
          err: File::NULL
        )

        puts "Uploaded branch refs for #{branch_name} branch to #{remote_path}"
      end

      def cache_files_list(ref)
        prefix = "s3://#{@s3_bucket}/#{@s3_path}/#{ref}/"

        `#{@aws_cli} s3 ls #{prefix} --recursive`.chomp.split("\n")
      end

      def download_file(ref, file_name)
        remote_path = File.join(s3_dir(ref), file_name)
        local_path = File.join(RSpecTracer.cache_path, file_name)

        raise AwsError, "Failed to download file #{remote_path}" unless system(
          @aws_cli,
          's3',
          'cp',
          remote_path,
          local_path,
          out: File::NULL,
          err: File::NULL
        )

        puts "Downloaded file #{remote_path} to #{local_path}"
      end

      def download_dir(ref, run_id)
        remote_dir = s3_dir(ref, run_id)
        local_dir = File.join(RSpecTracer.cache_path, run_id)

        raise AwsError, "Failed to download files from #{remote_dir}" unless system(
          @aws_cli,
          's3',
          'cp',
          remote_dir,
          local_dir,
          '--recursive',
          out: File::NULL,
          err: File::NULL
        )

        puts "Downloaded cache files from #{remote_dir} to #{local_dir}"
      rescue AwsError => e
        FileUtils.rm_rf(local_dir)

        raise e
      end

      def upload_file(ref, file_name)
        remote_path = File.join(s3_dir(ref), file_name)
        local_path = File.join(RSpecTracer.cache_path, file_name)

        raise AwsError, "Failed to upload file #{local_path}" unless system(
          @aws_cli,
          's3',
          'cp',
          local_path,
          remote_path,
          out: File::NULL,
          err: File::NULL
        )

        puts "Uploaded file #{local_path} to #{remote_path}"
      end

      def upload_dir(ref, run_id)
        remote_dir = s3_dir(ref, run_id)
        local_dir = File.join(RSpecTracer.cache_path, run_id)

        raise AwsError, "Failed to download files from #{local_dir}" unless system(
          @aws_cli,
          's3',
          'cp',
          local_dir,
          remote_dir,
          '--recursive',
          out: File::NULL,
          err: File::NULL
        )

        puts "Uploaded files from #{local_dir} to #{remote_dir}"
      end

      private

      def setup_s3
        s3_uri = ENV['RSPEC_TRACER_S3_URI']

        raise AwsError, 'RSPEC_TRACER_S3_URI environment variable is not set' if s3_uri.nil?

        uri_parts = s3_uri[4..-1].split('/')

        raise AwsError, "Invalid S3 URI #{s3_uri}" unless uri_parts.length >= 3 && uri_parts.first.empty?

        [
          uri_parts[1],
          uri_parts[2..-1].join('/')
        ]
      end

      def setup_aws_cli
        if ENV.fetch('LOCAL_AWS', 'false') == 'true'
          'awslocal'
        else
          'aws'
        end
      end

      def s3_dir(ref, run_id = nil)
        test_suite_id = ENV['TEST_SUITE_ID']

        if test_suite_id.nil?
          "s3://#{@s3_bucket}/#{@s3_path}/#{ref}/#{run_id}/".sub(%r{/+$}, '/')
        else
          "s3://#{@s3_bucket}/#{@s3_path}/#{ref}/#{test_suite_id}/#{run_id}/".sub(%r{/+$}, '/')
        end
      end
    end
  end
end
