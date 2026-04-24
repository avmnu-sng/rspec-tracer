# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer do
  describe '.parallel_tests_last_process?' do
    context 'when parallel_tests? is true and ::ParallelTests.first_process? returns true' do
      before do
        allow(described_class).to receive(:parallel_tests?).and_return(true)
        fake = Module.new do
          def self.first_process?
            true
          end
        end
        stub_const('::ParallelTests', fake)
      end

      it 'delegates to ::ParallelTests.first_process? (regression for v1.1.1 deadlock fix)' do
        expect(described_class.send(:parallel_tests_last_process?)).to be(true)
      end

      # Stubbing File.open as a mock-message is the cleanest way to prove
      # the lock-file path isn't consulted. have_received would require
      # installing File as a partial spy first, with its own teardown
      # hazards — the negation is clearer here.
      it 'does not read the rspec-tracer lock file' do
        expect(File).not_to receive(:open).with(match(/parallel_tests\.lock/), anything) # rubocop:disable RSpec/MessageSpies
        described_class.send(:parallel_tests_last_process?)
      end
    end

    context 'when parallel_tests? is true and ::ParallelTests.first_process? returns false' do
      before do
        allow(described_class).to receive(:parallel_tests?).and_return(true)
        fake = Module.new do
          def self.first_process?
            false
          end
        end
        stub_const('::ParallelTests', fake)
      end

      it 'returns false when not the first worker' do
        expect(described_class.send(:parallel_tests_last_process?)).to be(false)
      end
    end
  end
end
