# frozen_string_literal: true

RSpecTracer.configure do
  log_level :warn

  filters.clear
  add_filter '/vendor/bundle/'

  coverage_filters.clear
  add_coverage_filter %w[
    /autotest/
    /features/
    /spec/
    /test/
    /vendor/bundle/
  ].freeze
end
