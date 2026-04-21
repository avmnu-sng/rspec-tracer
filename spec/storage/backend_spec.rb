# frozen_string_literal: true

require 'rspec_tracer/storage/backend'

RSpec.describe RSpecTracer::Storage::Backend do
  describe 'REQUIRED_METHODS' do
    it 'is frozen so callers cannot mutate the required-method list' do
      expect(described_class::REQUIRED_METHODS).to be_frozen
    end

    it 'lists exactly the five protocol methods (load/save/last_run_id/transactional/clear)' do
      expect(described_class::REQUIRED_METHODS)
        .to eq(%i[load_graph save_graph last_run_id transactional_save clear!])
    end
  end

  describe '.conforms?' do
    def conformant_stub
      Class.new do
        def load_graph(*); end
        def save_graph(*); end
        def last_run_id; end
        def transactional_save(*); end
        def clear!; end
      end.new
    end

    def partial_stub
      Class.new do
        def load_graph(*); end
        def last_run_id; end
        def transactional_save(*); end
        def clear!; end
      end.new
    end

    it 'is true for an object responding to every required method' do
      expect(described_class.conforms?(conformant_stub)).to be(true)
    end

    it 'is false when any method is missing' do
      expect(described_class.conforms?(partial_stub)).to be(false)
    end
  end
end
