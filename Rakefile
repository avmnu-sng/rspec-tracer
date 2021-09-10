# frozen_string_literal: true

require 'rubocop/rake_task'
RuboCop::RakeTask.new

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:rspec)

Dir.glob('tasks/features/**/*.rake') { |task| load task }

task default: %i[
  rubocop
  rspec
  features:coverage:rspec_tracer:measure_line_coverage
  features:coverage:simplecov:measure_branch_coverage
  features:coverage:simplecov:measure_line_coverage
  features:validation:rspec_tracer:validate_line_coverage
  features:validation:simplecov:validate_branch_coverage
  features:validation:simplecov:validate_line_coverage
]
