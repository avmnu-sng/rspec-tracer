# frozen_string_literal: true

require 'rubocop/rake_task'
RuboCop::RakeTask.new

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)

namespace :features do
  desc 'Run feature specs on sample ruby project'
  task :ruby do
    puts "\nRunning feature specs on sample Ruby project..."

    command = <<-COMMAND.strip.gsub(/\s+/, ' ')
      RSPEC_VERSION="~> 3.10.0"
      SIMPLECOV_VERSION="~> 0.21.0"
      BRANCH_COVERAGE="true"
      bundle exec cucumber features/ruby_app_*.feature
    COMMAND

    exit(1) unless system(command)
  end

  desc 'Run feature specs on sample rails project'
  task :rails do
    puts "\nRunning feature specs on sample Rails project..."

    command = <<-COMMAND.strip.gsub(/\s+/, ' ')
      RAILS_VERSION="~> 6.1.0"
      RSPEC_RAILS_VERSION="~> 5.0.0"
      SIMPLECOV_VERSION="~> 0.21.0"
      BRANCH_COVERAGE="true"
      bundle exec cucumber features/rails_app_*.feature
    COMMAND

    exit(1) unless system(command)
  end
end

task default: %i[rubocop spec features:ruby features:rails]
