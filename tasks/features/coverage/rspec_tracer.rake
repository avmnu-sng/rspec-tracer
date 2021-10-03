# frozen_string_literal: true

namespace :features do
  namespace :coverage do
    namespace :rspec_tracer do
      desc 'Run ruby app feature specs for rspec tracer line coverage scenario to measure coverage'
      task :measure_line_coverage do
        puts "\nRunning features:coverage:rspec_tracer:measure_line_coverage\n"

        command = <<-COMMAND.strip.gsub(/\s+/, ' ')
          SKIP_COVERAGE_VALIDATION="true"
          SIMPLECOV_COMMAND_NAME="features:coverage:rspec_tracer"
          RSPEC_VERSION="~> 3.10"
          SIMPLECOV_VERSION="~> 0.21"
          bundle exec cucumber --retry 3 --no-strict-flaky --tags "@ruby-app and @no-simplecov"
        COMMAND

        exit(1) unless system(command)
      end
    end
  end
end
