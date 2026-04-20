# frozen_string_literal: true

require 'rspec_tracer'

RSpecTracer.start

require_relative '../app/calculator'
require_relative '../app/inventory'
require_relative '../app/discount'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
