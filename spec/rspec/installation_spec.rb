# frozen_string_literal: true

require 'rspec_tracer/rspec/installation'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:disable RSpec/InstanceVariable, Naming/PredicateMethod, Naming/MethodParameterName
RSpec.describe RSpecTracer::RSpec::Installation do
  describe '.install!' do
    let(:fake_runner)   { Class.new }
    let(:fake_reporter) { Class.new }

    before { allow(described_class).to receive(:warn_if_coverage_already_accumulated) }

    it 'prepends RunnerHook onto the runner class' do
      described_class.install!(runner_class: fake_runner, reporter_class: fake_reporter)

      expect(fake_runner.ancestors).to include(RSpecTracer::RSpec::RunnerHook)
    end

    it 'prepends ReporterHook onto the reporter class' do
      described_class.install!(runner_class: fake_runner, reporter_class: fake_reporter)

      expect(fake_reporter.ancestors).to include(RSpecTracer::RSpec::ReporterHook)
    end

    it 'returns true' do
      expect(described_class.install!(runner_class: fake_runner, reporter_class: fake_reporter)).to be(true)
    end

    it 'is idempotent — prepending twice leaves one copy in the ancestors chain' do
      described_class.install!(runner_class: fake_runner, reporter_class: fake_reporter)
      first_count = fake_runner.ancestors.count(RSpecTracer::RSpec::RunnerHook)
      described_class.install!(runner_class: fake_runner, reporter_class: fake_reporter)

      expect(fake_runner.ancestors.count(RSpecTracer::RSpec::RunnerHook)).to eq(first_count)
    end

    it 'delegates the load-order warning to warn_if_coverage_already_accumulated' do
      described_class.install!(runner_class: fake_runner, reporter_class: fake_reporter)

      expect(described_class).to have_received(:warn_if_coverage_already_accumulated)
    end

    it 'defaults to ::RSpec::Core::Runner + ::RSpec::Core::Reporter when no kwargs given' do
      # Smoke-level check: the method signature resolves without error.
      # Full behaviour is exercised end-to-end via the integration specs.
      params = described_class.method(:install!).parameters.map { |type, name| [type, name] }

      expect(params).to include(%i[key runner_class], %i[key reporter_class])
    end
  end

  describe '.warn_if_coverage_already_accumulated' do
    let(:logger) { spy('logger') }
    let(:coverage_mod) do
      Module.new do
        def self.running?
          @running
        end

        class << self
          attr_writer :running
        end

        def self.peek_result
          @peek_result || {}
        end

        class << self
          attr_writer :peek_result
        end
      end
    end

    before do
      allow(RSpecTracer).to receive(:logger).and_return(logger)
      stub_const('Coverage', coverage_mod)
      coverage_mod.running = true
      coverage_mod.peek_result = {}
      hide_const('SimpleCov')
    end

    def many_files(n)
      (1..n).to_h { |i| ["lib/file_#{i}.rb", { lines: [1, nil, 2] }] }
    end

    it 'warns when Coverage has >= 10 files with positive strengths and SimpleCov is not running' do
      coverage_mod.peek_result = many_files(15)

      described_class.warn_if_coverage_already_accumulated

      expect(logger).to have_received(:warn).with(/coverage has already accumulated for 15 file/)
    end

    it 'does not warn when fewer than 10 files have accumulated' do
      coverage_mod.peek_result = many_files(5)

      described_class.warn_if_coverage_already_accumulated

      expect(logger).not_to have_received(:warn)
    end

    it 'does not warn when SimpleCov is running (SimpleCov-first is the documented order)' do
      coverage_mod.peek_result = many_files(20)
      simplecov_mod = Module.new do
        def self.running = true
      end
      stub_const('SimpleCov', simplecov_mod)

      described_class.warn_if_coverage_already_accumulated

      expect(logger).not_to have_received(:warn)
    end

    it 'does not warn when Coverage is not running' do
      coverage_mod.running = false

      described_class.warn_if_coverage_already_accumulated

      expect(logger).not_to have_received(:warn)
    end

    it 'does not warn when ::Coverage is not defined' do
      hide_const('Coverage')

      described_class.warn_if_coverage_already_accumulated

      expect(logger).not_to have_received(:warn)
    end

    it 'does not warn when Coverage.peek_result entries have no positive strengths' do
      coverage_mod.peek_result = (1..20).to_h { |i| ["lib/file_#{i}.rb", { lines: [nil, 0] }] }

      described_class.warn_if_coverage_already_accumulated

      expect(logger).not_to have_received(:warn)
    end

    it 'swallows StandardError from an ill-behaved Coverage.peek_result' do
      allow(coverage_mod).to receive(:peek_result).and_raise(StandardError, 'boom')

      expect { described_class.warn_if_coverage_already_accumulated }.not_to raise_error
      expect(logger).not_to have_received(:warn)
    end

    it 'counts array-shaped coverage entries (older Ruby formats) as well as hash-shaped ones' do
      array_shaped = (1..12).to_h { |i| ["lib/a_#{i}.rb", [1, nil, 2]] }

      coverage_mod.peek_result = array_shaped

      described_class.warn_if_coverage_already_accumulated

      expect(logger).to have_received(:warn).with(/12 file/)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:enable RSpec/InstanceVariable, Naming/PredicateMethod, Naming/MethodParameterName
