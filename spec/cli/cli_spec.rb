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
      expect(stdout.string).to include('explain <id>')
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
  end

  describe 'SUB_COMMANDS' do
    it 'lists exactly the 5 promised sub-commands per USER_FACING_SURFACE.md §10' do
      expect(described_class::SUB_COMMANDS.keys).to contain_exactly(
        'doctor', 'cache:info', 'cache:clear', 'report:open', 'explain'
      )
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations
