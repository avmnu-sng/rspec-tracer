# frozen_string_literal: true

require 'rspec_tracer/rspec/reporter_hook'

# rubocop:disable RSpec/MultipleExpectations, RSpec/VerifiedDoubles
# rubocop:disable RSpec/MultipleMemoizedHelpers, Style/MultilineBlockChain
RSpec.describe RSpecTracer::RSpec::ReporterHook do
  let(:reporter_class) do
    Class.new do
      attr_reader :super_calls

      def initialize
        @super_calls = []
      end

      %i[example_started example_finished example_passed example_failed example_pending].each do |m|
        define_method(m) { |example| @super_calls << [m, example] }
      end
    end.tap { |c| c.prepend(described_class) }
  end

  let(:reporter)          { reporter_class.new }
  let(:engine)            { spy('Engine') }
  let(:execution_result)  { double('ExecutionResult') }
  let(:example) do
    double('Example',
           metadata: { rspec_tracer_example_id: 'ex1' },
           execution_result: execution_result)
  end

  before do
    allow(RSpecTracer).to receive(:engine).and_return(engine)
  end

  describe '#example_started' do
    it 'opens the engine bucket, then calls super' do
      reporter.example_started(example)

      expect(engine).to have_received(:example_started)
      expect(reporter.super_calls).to eq([[:example_started, example]])
    end

    it 'short-circuits (still calls super) when the engine is absent' do
      allow(RSpecTracer).to receive(:engine).and_return(nil)

      reporter.example_started(example)

      expect(engine).not_to have_received(:example_started)
      expect(reporter.super_calls).to eq([[:example_started, example]])
    end
  end

  describe '#example_finished' do
    it 'closes the engine bucket, then calls super' do
      reporter.example_finished(example)

      expect(engine).to have_received(:example_finished).with('ex1')
      expect(reporter.super_calls).to eq([[:example_finished, example]])
    end

    it 'skips engine notification when the example was ignored (no tracer id set)' do
      ignored_example = double('IgnoredExample', metadata: {}, execution_result: execution_result)

      reporter.example_finished(ignored_example)

      expect(engine).not_to have_received(:example_finished)
      expect(reporter.super_calls).to eq([[:example_finished, ignored_example]])
    end

    it 'short-circuits when engine is absent' do
      allow(RSpecTracer).to receive(:engine).and_return(nil)

      reporter.example_finished(example)

      expect(engine).not_to have_received(:example_finished)
      expect(reporter.super_calls).to eq([[:example_finished, example]])
    end
  end

  %i[example_passed example_failed example_pending].each do |callback|
    describe "##{callback}" do
      let(:engine_method) { :"on_#{callback}" }

      it "forwards the example id + execution_result to Engine##{:"on_#{callback}"}" do
        reporter.public_send(callback, example)

        expect(engine).to have_received(engine_method).with('ex1', execution_result)
        expect(reporter.super_calls).to eq([[callback, example]])
      end

      it 'is a no-op on the engine when the example was ignored' do
        ignored = double('IgnoredExample', metadata: {}, execution_result: execution_result)

        reporter.public_send(callback, ignored)

        expect(engine).not_to have_received(engine_method)
        expect(reporter.super_calls).to eq([[callback, ignored]])
      end

      it 'short-circuits when the engine is absent' do
        allow(RSpecTracer).to receive(:engine).and_return(nil)

        reporter.public_send(callback, example)

        expect(engine).not_to have_received(engine_method)
        expect(reporter.super_calls).to eq([[callback, example]])
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/VerifiedDoubles
# rubocop:enable RSpec/MultipleMemoizedHelpers, Style/MultilineBlockChain
