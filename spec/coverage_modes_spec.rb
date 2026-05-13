# frozen_string_literal: true

require 'rspec_tracer'

# Direct tests for RSpecTracer.setup_coverage's interaction with Ruby's
# `::Coverage` module. Three regressions / additions land here:
#
#   * pre-#195: bare `Coverage.start` crashes with
#     "coverage measurement is already setup" when a user pre-starts
#     Coverage to opt into branches before `RSpecTracer.start`. The
#     `Coverage.running?` guard mirrors `Engine#ensure_coverage_started`
#     so both entry points agree on the predicate.
#   * pre-#195: standalone path always used the bare `Coverage.start`
#     default (lines only). The new `coverage_modes` config DSL
#     threads `[:lines, :branches, :methods, :oneshot_lines, :eval]`
#     through to `Coverage.start(**modes)`.
#   * SimpleCov interop unchanged: when SimpleCov is loaded and
#     running, `setup_coverage` returns immediately (the DSL is inert
#     under SimpleCov, which owns the Coverage lifecycle via
#     `enable_coverage :branch` etc.).
RSpec.describe RSpecTracer, '.setup_coverage + #coverage_modes (issue #195)' do
  before do
    # Reset memoized @simplecov / @coverage_modes between examples.
    described_class.remove_instance_variable(:@simplecov) if described_class.instance_variable_defined?(:@simplecov)
    if described_class.instance_variable_defined?(:@coverage_modes)
      described_class.remove_instance_variable(:@coverage_modes)
    end
    hide_const('SimpleCov') if defined?(SimpleCov)
  end

  describe '.setup_coverage with no pre-started Coverage' do
    before do
      allow(Coverage).to receive(:respond_to?).and_call_original
      allow(Coverage).to receive(:respond_to?).with(:running?).and_return(true)
      allow(Coverage).to receive(:running?).and_return(false)
      allow(Coverage).to receive(:start)
    end

    it 'calls Coverage.start with the default lines-only mode' do
      described_class.send(:setup_coverage)

      expect(Coverage).to have_received(:start).with(lines: true)
    end

    it 'threads coverage_modes [:lines, :branches] through to Coverage.start' do
      described_class.coverage_modes(%i[lines branches])

      described_class.send(:setup_coverage)

      expect(Coverage).to have_received(:start).with(lines: true, branches: true)
    end

    it 'threads every documented mode through' do
      described_class.coverage_modes(%i[lines branches methods oneshot_lines eval])

      described_class.send(:setup_coverage)

      expect(Coverage).to have_received(:start)
        .with(lines: true, branches: true, methods: true, oneshot_lines: true, eval: true)
    end
  end

  describe '.setup_coverage when Coverage is already running' do
    before do
      allow(Coverage).to receive(:respond_to?).and_call_original
      allow(Coverage).to receive(:respond_to?).with(:running?).and_return(true)
      allow(Coverage).to receive(:running?).and_return(true)
      allow(Coverage).to receive(:start)
    end

    it 'does not crash (the #195 reproduction: pre-started Coverage)' do
      expect { described_class.send(:setup_coverage) }.not_to raise_error
    end

    it 'does not re-call Coverage.start' do
      described_class.send(:setup_coverage)

      expect(Coverage).not_to have_received(:start)
    end
  end

  describe '.setup_coverage on Rubies without Coverage.running?' do
    before do
      allow(Coverage).to receive(:respond_to?).and_call_original
      allow(Coverage).to receive(:respond_to?).with(:running?).and_return(false)
      allow(Coverage).to receive(:start).and_raise(RuntimeError, 'coverage measurement is already setup')
    end

    it 'rescues RuntimeError defensively (matches Engine#ensure_coverage_started)' do
      expect { described_class.send(:setup_coverage) }.not_to raise_error
    end
  end

  describe '.setup_coverage when SimpleCov is running' do
    before do
      simplecov_stub = Module.new
      simplecov_stub.singleton_class.define_method(:running) { true }
      stub_const('SimpleCov', simplecov_stub)
      allow(Coverage).to receive(:start)
    end

    it 'returns early (SimpleCov owns Coverage.start; DSL is inert)' do
      described_class.send(:setup_coverage)

      expect(Coverage).not_to have_received(:start)
    end

    # rubocop:disable RSpec/ExampleLength
    it 'still threads modes through when SimpleCov is NOT running (sanity)' do
      hide_const('SimpleCov')
      allow(Coverage).to receive(:respond_to?).and_call_original
      allow(Coverage).to receive(:respond_to?).with(:running?).and_return(true)
      allow(Coverage).to receive(:running?).and_return(false)
      described_class.coverage_modes(%i[lines branches])

      described_class.send(:setup_coverage)

      expect(Coverage).to have_received(:start).with(lines: true, branches: true)
    end
    # rubocop:enable RSpec/ExampleLength
  end
end
