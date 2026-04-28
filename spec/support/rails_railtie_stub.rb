# frozen_string_literal: true

# Test-only boot helper for mutant. The dev Gemfile does not include
# Rails, so `::Rails::Railtie` is not in the object graph. Defining a
# minimal stub here lets `lib/rspec_tracer/rails/railtie.rb`'s
# `class Railtie < ::Rails::Railtie` declaration evaluate at file load,
# which is required for mutant to bootstrap the subject. The spec at
# `spec/rails/railtie_spec.rb` independently stubs `Rails::Railtie`
# per-example via `stub_const`, so this boot stub gets replaced before
# any test body runs - it only exists to make the load-time class
# declaration evaluate.

unless defined?(Rails::Railtie)
  module Rails
    Railtie = Class.new do
      # Block argument is implicit and dropped; the real Railtie.initializer
      # registers the block, but for mutant boot we only need the call to
      # not raise.
      def self.initializer(_name); end
    end
  end
end

require 'rspec_tracer/rails/railtie'
