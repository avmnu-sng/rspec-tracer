# frozen_string_literal: true

# Loading the preset defines `RSpecTracer::Rails`, which is the module
# under test. The `rails.rb` entry-point require exercises the same load
# path but via the `load` helper inside individual examples.
require 'rspec_tracer/rails/preset'

RSpec.describe RSpecTracer::Rails do
  let(:entry_path) { File.expand_path('../../lib/rspec_tracer/rails.rb', __dir__) }

  describe 'requiring rspec_tracer/rails' do
    it 'loads without raising when Rails is absent' do
      hide_const('Rails') if defined?(Rails)

      expect { load entry_path }.not_to raise_error
    end

    it 'defines RSpecTracer::Rails::Preset regardless of Rails presence' do
      load entry_path

      expect(described_class.const_defined?(:Preset)).to be(true)
    end

    it 'skips loading the Railtie when Rails::Railtie is not defined' do
      hide_const('Rails::Railtie') if defined?(Rails::Railtie)
      # rubocop:disable RSpec/RemoveConst
      described_class.send(:remove_const, :Railtie) if described_class.const_defined?(:Railtie, false)
      # rubocop:enable RSpec/RemoveConst

      load entry_path

      expect(described_class.const_defined?(:Railtie, false)).to be(false)
    end
  end

  describe 'RSpecTracer.rails?' do
    around do |example|
      had_var = RSpecTracer.instance_variable_defined?(:@rails)
      original = RSpecTracer.instance_variable_get(:@rails) if had_var

      example.run
    ensure
      if had_var
        RSpecTracer.instance_variable_set(:@rails, original)
      elsif RSpecTracer.instance_variable_defined?(:@rails)
        RSpecTracer.remove_instance_variable(:@rails)
      end
    end

    # Matches `simplecov?` / `parallel_tests?` semantics: the predicate
    # short-circuits on `defined?(@rails)` and returns nil before the
    # flag has been computed. Callers branch on truthiness.
    it 'is falsy when @rails has never been set' do
      RSpecTracer.remove_instance_variable(:@rails) if RSpecTracer.instance_variable_defined?(:@rails)

      expect(RSpecTracer).not_to be_rails
    end

    it 'is false when Rails is not defined at detection time' do
      hide_const('Rails') if defined?(Rails)

      RSpecTracer.send(:setup_rails)

      expect(RSpecTracer.rails?).to be(false)
    end

    it 'is true when Rails::VERSION is defined at detection time' do
      stub_const('Rails', Module.new)
      stub_const('Rails::VERSION', '7.1.0')

      RSpecTracer.send(:setup_rails)

      expect(RSpecTracer).to be_rails
    end

    it 'is false when Rails is present but Rails::VERSION is nil' do
      stub_const('Rails', Module.new)
      stub_const('Rails::VERSION', nil)

      RSpecTracer.send(:setup_rails)

      expect(RSpecTracer.rails?).to be(false)
    end

    it 'memoizes the flag across multiple reads (no re-detection)' do
      stub_const('Rails', Module.new)
      stub_const('Rails::VERSION', '7.1.0')
      RSpecTracer.send(:setup_rails)
      hide_const('Rails')
      expect(RSpecTracer.rails?).to be(true)
    end
  end
end
