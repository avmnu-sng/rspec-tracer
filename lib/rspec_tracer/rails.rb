# frozen_string_literal: true

# Rails integration entry point. Loaded explicitly by users who put
# `require 'rspec_tracer/rails'` in their spec_helper - the gem does not
# auto-load this file, so pure-Ruby suites pay zero cost.
#
# Behavior:
#   - Always loads RSpecTracer::Rails::Preset so Configuration#track_rails_defaults
#     works whether or not Rails itself is booted in the current process.
#   - Loads RSpecTracer::Rails::Railtie iff `::Rails::Railtie` is defined,
#     so requiring this file when Rails is absent is a clean no-op
#     (AC1: "Rails absent: requiring rspec_tracer/rails noops cleanly").

require_relative 'rails/preset'
require_relative 'rails/railtie' if defined?(Rails::Railtie)
