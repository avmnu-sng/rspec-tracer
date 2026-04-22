# frozen_string_literal: true

require 'set'

require 'rspec_tracer/rspec/runner_hook'

# Unit coverage for RSpecTracer::RSpec::RunnerHook. Uses an anonymous
# class for the prepend target so installation onto the real
# RSpec::Core::Runner (which already happened at spec_helper load
# time) doesn't leak into the assertions.
#
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:disable RSpec/MultipleMemoizedHelpers, Style/MultilineBlockChain
RSpec.describe RSpecTracer::RSpec::RunnerHook do
  let(:runner_class) do
    Class.new do
      attr_reader :super_calls

      def initialize
        @super_calls = []
      end

      def run_specs(example_groups)
        @super_calls << example_groups
        :super_result
      end
    end.tap { |c| c.prepend(described_class) }
  end

  let(:runner)     { runner_class.new }
  let(:engine)     { double('Engine') }
  let(:logger)     { spy('logger') }
  let(:world)      { double('RSpec.world') }

  let(:example_group) { double('ExampleGroup') }
  let(:example_metadata) { { file_path: 'spec/foo_spec.rb' } }
  let(:example) do
    double('Example', metadata: example_metadata, description: 'does things',
                      example_group: double('EG', parent_groups: [example_group]))
  end
  let(:tracer_example) { { example_id: 'ex1' } }

  before do
    allow(RSpec).to receive(:world).and_return(world)
    allow(RSpecTracer).to receive(:running=)
    allow(RSpecTracer).to receive(:no_examples=)
    allow(RSpecTracer).to receive(:duplicate_examples=)
    allow(RSpecTracer).to receive_messages(engine: engine, logger: logger, fail_on_duplicates: false,
                                           ignore_spec_file?: false)
    allow(RSpecTracer::Example).to receive(:from).and_return(tracer_example)
    allow(engine).to receive_messages(run_example?: true, run_example_reason: 'No cache',
                                      duplicate_examples: {})
    allow(engine).to receive(:register_example)
    allow(engine).to receive(:on_example_skipped)
    allow(engine).to receive(:deregister_duplicate_examples)
  end

  describe '#run_specs' do
    context 'when the engine is absent (graceful degrade)' do
      before { allow(RSpecTracer).to receive(:engine).and_return(nil) }

      it 'calls super directly without touching RSpec.world' do
        allow(world).to receive(:example_count).and_return(42) # unused in this path

        result = runner.run_specs([:group1])

        expect(result).to eq(:super_result)
        expect(runner.super_calls).to eq([[:group1]])
      end
    end

    context 'when there are zero examples' do
      before { allow(world).to receive(:example_count).and_return(0) }

      it 'flips the no_examples + running flags and forwards to super unchanged' do
        runner.run_specs([:group_a])

        expect(RSpecTracer).to have_received(:running=).with(true)
        expect(RSpecTracer).to have_received(:no_examples=).with(true)
        expect(runner.super_calls).to eq([[:group_a]])
      end
    end

    context 'when duplicate examples are detected' do
      before do
        allow(world).to receive_messages(example_count: 1, filtered_examples: {})
        allow(engine).to receive(:duplicate_examples).and_return(
          'ex1' => [{ example_id: 'ex1' }, { example_id: 'ex1' }]
        )
        allow(RSpecTracer).to receive(:fail_on_duplicates).and_return(true)
      end

      it 'logs an error, flips duplicate_examples, and calls super with an empty list' do
        runner.run_specs([:original])

        expect(logger).to have_received(:error).with(/2 duplicate example\(s\) across 1 identity hash/)
        expect(RSpecTracer).to have_received(:duplicate_examples=).with(true)
        expect(runner.super_calls).to eq([[]])
      end
    end

    context 'when examples are tracked and the engine schedules a run' do
      before do
        allow(world).to receive(:example_count).and_return(2, 1)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
      end

      it 'registers the example, updates metadata, and delegates to super with the filtered set' do
        runner.run_specs([])

        expect(engine).to have_received(:register_example).with(hash_including(run_reason: 'No cache'))
        expect(example_metadata).to include(rspec_tracer_example_id: 'ex1')
        expect(example_metadata[:description]).to include('(No cache)')
        expect(world).to have_received(:instance_variable_set)
          .with(:@filtered_examples, hash_including(example_group => [example]))
        expect(world).to have_received(:instance_variable_set)
          .with(:@example_groups, [example_group])
        expect(runner.super_calls.last).to eq([example_group])
        expect(logger).to have_received(:info).with(/RSpec tracer is running 1 examples/)
      end
    end

    context 'when the engine filters an example out' do
      before do
        allow(world).to receive(:example_count).and_return(1, 0)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
        allow(engine).to receive(:run_example?).with('ex1').and_return(false)
      end

      it 'notifies the engine of the skip and does not call register_example' do
        runner.run_specs([])

        expect(engine).to have_received(:on_example_skipped).with('ex1')
        expect(engine).not_to have_received(:register_example)
      end
    end

    context 'when an example matches ignore_spec_files' do
      before do
        allow(RSpecTracer).to receive(:ignore_spec_file?).with('spec/foo_spec.rb').and_return(true)
        allow(world).to receive(:example_count).and_return(1, 1)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
      end

      it 'passes the example through without registering or hashing it' do
        runner.run_specs([])

        expect(RSpecTracer::Example).not_to have_received(:from)
        expect(engine).not_to have_received(:register_example)
        expect(engine).not_to have_received(:on_example_skipped)
        expect(example_metadata).not_to include(:rspec_tracer_example_id)
        expect(world).to have_received(:instance_variable_set)
          .with(:@filtered_examples, hash_including(example_group => [example]))
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:enable RSpec/MultipleMemoizedHelpers, Style/MultilineBlockChain
