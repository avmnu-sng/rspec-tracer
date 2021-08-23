# frozen_string_literal: true

module RSpecTracer
  module RubyCoverage
    def result
      RSpecTracer.coverage_reporter.coverage
    end
  end
end
