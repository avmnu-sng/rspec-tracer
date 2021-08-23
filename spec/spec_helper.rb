# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/vendor/bundle/'
  track_files 'lib/**/*.rb'
end

require 'rspec_tracer'
RSpecTracer.start

RSpec.configure do |config|
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
