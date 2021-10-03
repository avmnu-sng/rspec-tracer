# frozen_string_literal: true

namespace :features do
  namespace :validation do
    namespace :simplecov do
      desc 'Run ruby app feature specs for simplecov branch coverage scenario to validate'
      task :validate_branch_coverage do
        puts "\nRunning features:validation:simplecov:validate_branch_coverage\n"

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          SKIP_COVERAGE_VALIDATION="false"
          RSPEC_VERSION="~> 3.10"
          SIMPLECOV_VERSION="~> 0.21"
          BRANCH_COVERAGE="true"
          bundle exec cucumber --retry 3 --no-strict-flaky --tags "@ruby-app and @simplecov and @branch-coverage"
        COMMAND

        exit(1) unless system(command)
      end

      desc 'Run ruby app feature specs for simplecov line coverage scenario to validate'
      task :validate_line_coverage do
        puts "\nRunning features:validation:simplecov:validate_line_coverage\n"

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          SKIP_COVERAGE_VALIDATION="false"
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
