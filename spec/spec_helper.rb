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

# Skip the tracer self-instrumentation when running under mutant — the
# tracer's own Runner boot path calls TimeFormatter.format_time, and any
# mutation that makes that raise would prevent the spec_helper from
# loading at all, leaving mutant unable to distinguish "killed" from
# "setup crashed".
RSpecTracer.start unless ENV['RSPEC_TRACER_DISABLE'] == '1'

RSpec.configure do |config|
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
