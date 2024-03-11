# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    class Validator
      CACHE_FILES_PER_TEST_SUITE = 11

      def initialize
        @test_suite_id = ENV['TEST_SUITE_ID']
        @test_suites = ENV['TEST_SUITES']
        @use_test_suite_id_cache = ENV['USE_TEST_SUITE_ID_CACHE'] == 'true'

        if @test_suite_id.nil? ^ @test_suites.nil?
          raise(
            ValidationError,
            'Both the environment variables TEST_SUITE_ID and TEST_SUITES are not set'
          )
        end

        setup
      end

      def valid?(ref, cache_files)
        if @use_test_suite_id_cache
          test_suite_id_specific_validation(ref, cache_files)
        else
          general_validation(ref, cache_files)
        end
      end

      private

      def setup
        if @test_suites.nil?
          @last_run_files_count = 1
          @last_run_files_regex = '/%<ref>s/last_run.json$'
          @cached_files_count = CACHE_FILES_PER_TEST_SUITE
          @cached_files_regex = '/%<ref>s/[0-9a-f]{32}/.+.json$'
        else
          @test_suites = @test_suites.to_i
          @test_suites_regex = (1..@test_suites).to_a.join('|')

          @last_run_files_count = @test_suites
          @last_run_files_regex = "/%<ref>s/(#{@test_suites_regex})/last_run.json$"
          @cached_files_count = CACHE_FILES_PER_TEST_SUITE * @test_suites
          @cached_files_regex = "/%<ref>s/(#{@test_suites_regex})/[0-9a-f]{32}/.+.json$"
        end
      end

      def general_validation(ref, cache_files)
        last_run_regex = Regexp.new(format(@last_run_files_regex, ref: ref))

        return false if cache_files.count { |file| file.match?(last_run_regex) } != @last_run_files_count

        cache_regex = Regexp.new(format(@cached_files_regex, ref: ref))

        cache_files.count { |file| file.match?(cache_regex) } == @cached_files_count
      end

      def test_suite_id_specific_validation(ref, cache_files)
        # Here, we ensure that the regex is dynamically adjusted for the specific test suite
        # Adjusting for specific test_suite_id in the regex patterns
        last_run_regex = Regexp.new("/#{ref}/#{@test_suite_id}/last_run.json$")
        cache_regex = Regexp.new("/#{ref}/#{@test_suite_id}/[0-9a-f]{32}/.+.json$")

        # Validate presence of the last run file for the specific test suite
        return false unless cache_files.any? { |file| file.match?(last_run_regex) }

        # Check if any cache files for the specific test suite are present
        cache_files.any? { |file| file.match?(cache_regex) }
      end
    end
  end
end
