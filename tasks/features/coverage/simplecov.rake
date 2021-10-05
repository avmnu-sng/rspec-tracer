# frozen_string_literal: true

namespace :features do
  namespace :coverage do
    namespace :simplecov do
      desc 'Run ruby app feature specs for simplecov branch coverage scenario to measure coverage'
      task :measure_branch_coverage do
        puts "\nRunning features:coverage:simplecov:measure_branch_coverage\n"

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          SKIP_COVERAGE_VALIDATION="true"
          SIMPLECOV_COMMAND_NAME="features:coverage:simplecov:branch_coverage"
          RSPEC_VERSION="~> 3.10"
          SIMPLECOV_VERSION="~> 0.21"
          BRANCH_COVERAGE="true"
          bundle exec cucumber --retry 3 --no-strict-flaky --tags "@ruby-app and @simplecov and @branch-coverage"
        COMMAND

        exit(1) unless system(command)
      end

      desc 'Run ruby app feature specs for simplecov line coverage scenario to measure coverage'
      task :measure_line_coverage do
        puts "\nRunning features:coverage:simplecov:measure_line_coverage\n"

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          SKIP_COVERAGE_VALIDATION="true"
          SIMPLECOV_COMMAND_NAME="features:coverage:simplecov:line_coverage"
          RSPEC_VERSION="~> 3.10"
          SIMPLECOV_VERSION="~> 0.21"
          BRANCH_COVERAGE="false"
          bundle exec cucumber --retry 3 --no-strict-flaky --tags "@ruby-app and @simplecov and not @branch-coverage"
        COMMAND

        exit(1) unless system(command)
      end
    end
  end
end
