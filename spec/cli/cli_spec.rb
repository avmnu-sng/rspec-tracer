# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

require 'rspec_tracer/cli'

# rubocop:disable RSpec/MultipleExpectations
RSpec.describe RSpecTracer::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints top-level help when invoked with no args' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('Usage: rspec-tracer <sub-command>')
      expect(stdout.string).to include('doctor')
      expect(stdout.string).to include('cache:info')
      expect(stdout.string).to include('explain <id>').and include('blast-radius <f>')
    end

    it 'prints top-level help on -h / --help / help' do
      %w[-h --help help].each do |flag|
        out = StringIO.new
        described_class.run([flag], stdout: out, stderr: stderr)
        expect(out.string).to include('Usage: rspec-tracer <sub-command>')
      end
    end

    it 'prints version on -v / --version' do
      %w[-v --version].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include("rspec-tracer #{RSpecTracer::VERSION}")
      end
    end

    it 'returns 1 with a clear error on unknown sub-command' do
      expect(described_class.run(%w[bogus], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('unknown sub-command')
      expect(stderr.string).to include('"bogus"')
      expect(stderr.string).to include('available:')
    end

    it 'rescues StandardError from sub-command dispatch and returns 1' do
      stub_const('RSpecTracer::CLI::SUB_COMMANDS', { 'doctor' => 'NoSuchClass' })
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to start_with('rspec-tracer:')
    end

    it 'exits 0 silently when a downstream pipe closes early (broken pipe from `| head`)' do
      broken = StringIO.new
      allow(broken).to receive(:puts).and_raise(Errno::EPIPE)
      expect(described_class.run(%w[--help], stdout: broken, stderr: stderr)).to eq(0)
      expect(stderr.string).to be_empty
    end

    # rubocop:disable RSpec/ExampleLength
    it 'routes tracer logger diagnostics to stderr during dispatch and restores the logger after' do
      # Backend degradation messages (sqlite-unavailable fallback,
      # schema-mismatch info) go through RSpecTracer.logger, whose
      # default destination is stdout. During CLI dispatch they must
      # land on stderr instead, so machine-readable sub-command output
      # (`blast-radius --json`) stays parseable.
      logger_before = RSpecTracer.logger
      allow(described_class).to receive(:dispatch) do
        RSpecTracer.logger.warn('diagnostic emitted mid-dispatch')
        0
      end
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stderr.string).to include('diagnostic emitted mid-dispatch')
      expect(stdout.string).to be_empty
      expect(RSpecTracer.logger).to equal(logger_before)
    end
    # rubocop:enable RSpec/ExampleLength

    it 'restores the previous logger even when dispatch raises' do
      logger_before = RSpecTracer.logger
      allow(described_class).to receive(:dispatch).and_raise(StandardError, 'dispatch boom')
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('dispatch boom')
      expect(RSpecTracer.logger).to equal(logger_before)
    end

    # rubocop:disable RSpec/ExampleLength
    it 'routes logger writes fired during library boot (config load) to stderr' do
      # The `.rspec-tracer` 1.x deprecation shims (`reports_s3_path`,
      # `use_local_aws`) write through a logger constructed WHILE
      # load_tracer boots the library -- before with_logger_on can
      # rebind the memoized instance. Logger.default_out must already
      # point at stderr inside that window, or the warning lands on
      # stdout ahead of machine-readable output (`blast-radius
      # --json`). End-to-end variant (real config, real subprocess):
      # spec/edge_cases/cli_deprecated_config_purity_spec.rb.
      allow(described_class).to receive(:load_tracer) do
        RSpecTracer::Logger.new(2).warn('deprecation fired at config load')
        true
      end
      allow(described_class).to receive(:dispatch).and_return(0)
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stderr.string).to include('deprecation fired at config load')
      expect(stdout.string).to be_empty
    end

    it 'binds Logger.default_out to stderr for the dispatch window and restores it after' do
      previous = RSpecTracer::Logger.default_out
      seen = nil
      allow(described_class).to receive(:dispatch) do
        seen = RSpecTracer::Logger.default_out
        0
      end
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(0)
      expect(seen).to equal(stderr)
      expect(RSpecTracer::Logger.default_out).to equal(previous)
    end
    # rubocop:enable RSpec/ExampleLength

    it 'restores Logger.default_out even when dispatch raises' do
      previous = RSpecTracer::Logger.default_out
      allow(described_class).to receive(:dispatch).and_raise(StandardError, 'dispatch boom')
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(1)
      expect(RSpecTracer::Logger.default_out).to equal(previous)
    end

    it 'returns 1 without dispatching when the tracer library fails to boot' do
      allow(described_class).to receive(:load_tracer).and_return(false)
      allow(described_class).to receive(:dispatch)
      expect(described_class.run(%w[doctor], stdout: stdout, stderr: stderr)).to eq(1)
      expect(described_class).not_to have_received(:dispatch)
    end

    it 'still prints help and version when the project config is broken' do
      allow(described_class).to receive(:load_tracer).and_return(false)
      expect(described_class.run(%w[--help], stdout: stdout, stderr: stderr)).to eq(0)
      version_out = StringIO.new
      expect(described_class.run(%w[--version], stdout: version_out, stderr: stderr)).to eq(0)
      expect(version_out.string).to include("rspec-tracer #{RSpecTracer::VERSION}")
    end
  end

  describe '.load_tracer' do
    it 'returns true when the tracer library (and the user configs) load cleanly' do
      expect(described_class.load_tracer(stderr)).to be(true)
      expect(stderr.string).to be_empty
    end

    it 'degrades a raising config to a one-line message and false' do
      allow(described_class).to receive(:require).with('rspec_tracer').and_raise(RuntimeError, 'boom at config load')
      expect(described_class.load_tracer(stderr)).to be(false)
      expect(stderr.string)
        .to include('rspec-tracer: could not load configuration (.rspec-tracer): RuntimeError: boom at config load')
    end

    it 'catches ScriptError so a config SyntaxError cannot escape as a backtrace' do
      # SyntaxError (raised by a corrupt `.rspec-tracer` at `load`
      # time) is a ScriptError, NOT a StandardError -- a bare
      # `rescue StandardError` would let it crash the binary.
      allow(described_class).to receive(:require).with('rspec_tracer').and_raise(SyntaxError, 'unexpected end')
      expect(described_class.load_tracer(stderr)).to be(false)
      expect(stderr.string).to include('SyntaxError')
      expect(stderr.string).to include('unexpected end')
    end
  end

  describe 'SUB_COMMANDS' do
    it 'lists exactly the 6 promised sub-commands' do
      expect(described_class::SUB_COMMANDS.keys).to contain_exactly(
        'doctor', 'cache:info', 'cache:clear', 'report:open', 'explain', 'blast-radius'
      )
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations
