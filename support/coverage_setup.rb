# frozen_string_literal: true

def setup_simplecov
  return unless ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'

  require 'simplecov'

  SimpleCov.command_name "#{ENV['SIMPLECOV_COMMAND_NAME']}:#{Process.pid}"
  SimpleCov.root File.expand_path('..', __dir__)

  SimpleCov.start do
    enable_coverage :branch if ENV.fetch('BRANCH_COVERAGE', 'false') == 'true'

    add_filter %w[/features/ /spec/ /tmp/]
  end
end

def setup_rspec_tracer
  return unless ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'

  require File.join(File.expand_path('..', __dir__), 'lib', 'rspec_tracer')

  RSpecTracer.configure do
    add_filter %w[
      /.rubies/ruby-head/ /.rvm/gems/ /.rvm/rubies/ /bundler/gems/
      /opt/hostedtoolcache/ /rspec-tracer/ /ruby/gems/ /vendor/bundle/
    ]

    add_coverage_filter %w[
      /.rubies/ruby-head/ /.rvm/gems/ /.rvm/rubies/ /bundler/gems/ /autotest/
      /features/ /opt/hostedtoolcache/ /ruby/gems/ /spec/ /test/ /vendor/bundle/
    ]
  end
end

if ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true' && File.file?('Gemfile.lock')
  setup_simplecov
  setup_rspec_tracer

  module RSpecTracerCoverageReporter
    def peek_coverage
      data = ::Coverage.peek_result

      return data if data.first.last.is_a?(Array)

      data.transform_values { |stats| stats[:lines] }
    end
  end

  main_clazz = RSpecTracer::CoverageReporter
  clazz = RSpecTracerCoverageReporter

  main_clazz.prepend(clazz) unless main_clazz.ancestors.include?(clazz)
end
