# frozen_string_literal: true

require 'bundler'
Bundler.setup

require 'simplecov'
require 'simplecov_json_formatter'

SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::JSONFormatter
].freeze

SimpleCov.start do
  enable_coverage :branch if ENV.fetch('BRANCH_COVERAGE', 'false') == 'true'

  add_filter %w[/features/ /spec/ /tmp/]
end

require 'aruba/cucumber'
require 'pry'

Before do
  if ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'
    setup_file = File.join(File.expand_path('../..', __dir__), 'support', 'coverage_setup')

    case RUBY_ENGINE
    when 'ruby'
      set_environment_variable('RUBYOPT', "-r#{setup_file} #{ENV['RUBYOPT']}")
    when 'jruby'
      set_environment_variable('JRUBY_OPTS', "--debug -X+O -r#{setup_file} #{ENV['JRUBY_OPTS']}")
    end
  end
end

Before('@branch-coverage') do
  skip_this_scenario unless ENV.fetch('BRANCH_COVERAGE', 'false') == 'true'
end
