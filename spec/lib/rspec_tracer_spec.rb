# frozen_string_literal: true

require 'spec_helper'

# Coverage for the 1.2.4 setup_coverage guard. The bug: when the user
# starts `Coverage` themselves (to opt into branch coverage) before
# loading rspec-tracer, `RSpecTracer.start` -> `setup_coverage` ->
# bare `Coverage.start` raised RuntimeError ("coverage measurement
# is already setup") and took the tracer down. The fix adds a
# `Coverage.running?` predicate guard plus a defensive RuntimeError
# rescue with a logger.warn — graceful degradation, no surprise crash.
#
# The tests force the standalone (non-SimpleCov) path because the
# spec_helper itself starts SimpleCov, which short-circuits the
# method before the new lines execute.
RSpec.describe RSpecTracer do
  describe '.setup_coverage' do
    before do
      # spec_helper has SimpleCov.running == true; bypass the
      # short-circuit so the test exercises the new guard path.
      allow(SimpleCov).to receive(:running).and_return(false)
    end

    it 'returns early when Coverage is already running (does not call Coverage.start)' do
      allow(Coverage).to receive(:running?).and_return(true)
      allow(Coverage).to receive(:start)

      described_class.send(:setup_coverage)

      expect(Coverage).not_to have_received(:start)
    end

    context 'when Coverage.start raises RuntimeError' do
      before do
        allow(Coverage).to receive(:running?).and_return(false)
        allow(Coverage).to receive(:start).and_raise(
          RuntimeError, 'coverage measurement is already setup'
        )
        allow(described_class.logger).to receive(:warn)
      end

      it 'rescues the error rather than propagating it' do
        expect { described_class.send(:setup_coverage) }.not_to raise_error
      end

      it 'logs a warn explaining the skip' do
        described_class.send(:setup_coverage)

        expect(described_class.logger).to have_received(:warn).with(/coverage measurement setup skipped/)
      end
    end
  end
end
