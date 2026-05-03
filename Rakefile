# frozen_string_literal: true

require 'rubocop/rake_task'
RuboCop::RakeTask.new

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:rspec)

task default: %i[rubocop rspec]
