# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    class Validator
      CACHE_FILES_PER_TEST_SUITE = 8

      def initialize
        @test_suite_id = ENV['TEST_SUITE_ID']
        @test_suites = ENV['TEST_SUITES']

        if @test_suite_id.nil? ^ @test_suites.nil?
          raise(
            ValidationError,
            'Both the enviornment variables TEST_SUITE_ID and TEST_SUITES are not set'
          )
        end

        setup
      end

      def valid?(ref, cache_files)
        last_run_regex = Regexp.new(format(@last_run_files_regex, ref: ref))

        return false if cache_files.count { |file| file.match?(last_run_regex) } != @last_run_files_count

        cache_regex = Regexp.new(format(@cached_files_regex, ref: ref))

        cache_files.count { |file| file.match?(cache_regex) } == @cached_files_count
      end

      private

      def setup
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
          @cached_files_count = CACHE_FILES_PER_TEST_SUITE * @test_suites
          @cached_files_regex = "/%<ref>s/(#{@test_suites_regex})/[0-9a-f]{32}/.+.json$"
        end
      end
    end
  end
end
