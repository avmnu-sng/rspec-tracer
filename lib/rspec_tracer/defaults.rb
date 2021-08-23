# frozen_string_literal: true

RSpecTracer.configure do
  add_filter '/vendor/bundle/'
  add_coverage_filter %w[/autotest/ /features/ /spec/ /test/].freeze
end

at_exit do
  RSpecTracer.at_exit_behavior
end
