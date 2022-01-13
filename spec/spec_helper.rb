# frozen_string_literal: true

require 'simplecov'
require 'simplecov_json_formatter'

SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::JSONFormatter
].freeze

SimpleCov.start do
  track_files 'lib/**/*.rb'
end

require 'rspec_tracer'

RSpecTracer::Configuration.module_exec do
  RSpecTracer::Configuration.instance_methods(false).each do |method_name|
    define_method method_name do |*args|
      send("_#{method_name}".to_sym, *args)
    end
  end
end

RSpecTracer.start

RSpec.configure do |config|
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
