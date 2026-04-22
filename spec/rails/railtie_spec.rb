# frozen_string_literal: true

# Loading the preset defines `RSpecTracer::Rails`, the module the
# Railtie class lives inside. Railtie.rb itself expects
# `::Rails::Railtie` to already be defined; the before-block below
# stubs that base class so this spec can run without the real Rails
# gem in the object graph.
require 'rspec_tracer/rails/preset'

RSpec.describe RSpecTracer::Rails do
  describe 'RSpecTracer::Rails::Railtie' do
    let(:railtie_path) do
      File.expand_path('../../lib/rspec_tracer/rails/railtie.rb', __dir__)
    end

    # The dev Gemfile does not include Rails, so a real ::Rails::Railtie
    # is not in the object graph. Provide a minimal stand-in that records
    # every `initializer(name, &block)` call so the spec can inspect what
    # the loaded railtie.rb registered. Full fixture-level boot happens
    # in M4.3's integration matrix.
    let(:railtie_base) do
      Class.new do
        class << self
          def initializer(name, &block)
            registered_initializers[name] = block
          end

          def registered_initializers
            @registered_initializers ||= {}
          end
        end
      end
    end

    before do
      stub_const('Rails', Module.new) unless defined?(Rails)
      stub_const('Rails::Railtie', railtie_base)

      # rubocop:disable RSpec/RemoveConst
      described_class.send(:remove_const, :Railtie) if described_class.const_defined?(:Railtie, false)
      # rubocop:enable RSpec/RemoveConst

      load railtie_path
    end

    it 'defines the class under RSpecTracer::Rails' do
      expect(described_class.const_defined?(:Railtie, false)).to be(true)
    end

    it 'subclasses the provided Rails::Railtie base' do
      expect(RSpecTracer::Rails::Railtie).to be < railtie_base
    end

    it 'registers exactly one initializer named rspec_tracer.setup' do
      expect(RSpecTracer::Rails::Railtie.registered_initializers.keys)
        .to contain_exactly('rspec_tracer.setup')
    end

    it 'logs a confirmation line when the initializer block runs' do
      allow(RSpecTracer.logger).to receive(:info)

      RSpecTracer::Rails::Railtie.registered_initializers['rspec_tracer.setup'].call

      expect(RSpecTracer.logger).to have_received(:info)
        .with(/rspec-tracer Rails integration loaded/)
    end
  end
end
