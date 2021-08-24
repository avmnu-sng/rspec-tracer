# frozen_string_literal: true

require 'bundler'
Bundler.setup

require 'aruba/cucumber'
require 'pry'

Before('@branch_coverage') do
  skip_this_scenario unless ENV.fetch('BRANCH_COVERAGE', 'false') == 'true'
end
