# frozen_string_literal: true

require 'rspec_tracer'

# M8.9: SimpleCov load-order is part of the documented contract -
# SimpleCov.start MUST run before RSpecTracer.start when both are
# used. When the user has SimpleCov loaded but not started, we'd
# silently call ::Coverage.start and SimpleCov's later setup would
# bolt onto a Coverage already in flight; coverage filters mis-apply.
# `RSpecTracer.warn_on_simplecov_load_order_mistake` surfaces the
# mistake at start time so the user sees a one-line warn instead of
# mysteriously-broken coverage.
RSpec.describe RSpecTracer, '.warn_on_simplecov_load_order_mistake' do
  let(:logger) { instance_double(RSpecTracer::Logger, debug: nil, info: nil, warn: nil, error: nil) }

  before do
    allow(described_class).to receive(:logger).and_return(logger)
  end

  context 'when SimpleCov is not loaded' do
    before { hide_const('SimpleCov') if defined?(SimpleCov) }

    it 'does not warn' do
      described_class.send(:warn_on_simplecov_load_order_mistake)
      expect(logger).not_to have_received(:warn)
    end
  end

  context 'when SimpleCov is loaded but has not been started' do
    before do
      simplecov_stub = Module.new
      simplecov_stub.singleton_class.define_method(:running) { false }
      stub_const('SimpleCov', simplecov_stub)
    end

    it 'warns about the load-order mistake with an actionable hint' do
      described_class.send(:warn_on_simplecov_load_order_mistake)
      expect(logger).to have_received(:warn).with(
        a_string_including('SimpleCov is loaded but not started')
        .and(a_string_including('Call SimpleCov.start before RSpecTracer.start'))
      )
    end
  end

  context 'when SimpleCov is loaded and running' do
    before do
      simplecov_stub = Module.new
      simplecov_stub.singleton_class.define_method(:running) { true }
      stub_const('SimpleCov', simplecov_stub)
    end

    it 'does not warn (canonical load order honored)' do
      described_class.send(:warn_on_simplecov_load_order_mistake)
      expect(logger).not_to have_received(:warn)
    end
  end

  context 'when SimpleCov is loaded but does not expose the running predicate' do
    before do
      stub_const('SimpleCov', Module.new)
    end

    it 'warns (defensive: treat unknown SimpleCov state as "not started")' do
      described_class.send(:warn_on_simplecov_load_order_mistake)
      expect(logger).to have_received(:warn).with(/SimpleCov is loaded but not started/)
    end
  end
end
