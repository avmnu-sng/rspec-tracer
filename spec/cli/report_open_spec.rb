# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'rspec_tracer/cli/report_open'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::CLI::ReportOpen do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer report:open')
      end
    end

    it 'returns 1 with a clear error when index.html is missing' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive(:report_path).and_return(dir)
        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no report at')
        expect(stderr.string).to include('run rspec first')
      end
    end

    it 'returns 0 and prints the path when no opener is detected' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'index.html'), '<html></html>')
        allow(RSpecTracer).to receive(:report_path).and_return(dir)
        allow(described_class).to receive(:detect_opener).and_return(nil)

        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('no opener detected')
      end
    end

    it 'launches the opener and returns 0 on success' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'index.html'), '<html></html>')
        allow(RSpecTracer).to receive(:report_path).and_return(dir)
        allow(described_class).to receive_messages(detect_opener: 'open')
        allow(described_class).to receive(:system).and_return(true)

        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('opened')
      end
    end

    it 'returns 1 when the opener launch fails' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'index.html'), '<html></html>')
        allow(RSpecTracer).to receive(:report_path).and_return(dir)
        allow(described_class).to receive_messages(detect_opener: 'open')
        allow(described_class).to receive(:system).and_return(false)

        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('failed to launch')
      end
    end

    it 'rescues StandardError and returns 1' do
      allow(RSpecTracer).to receive(:report_path).and_raise(StandardError, 'report resolve boom')

      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('report:open:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.detect_opener' do
    it 'returns nil when neither open nor xdg-open is on PATH' do
      allow(described_class).to receive(:which).and_return(nil)

      expect(described_class.detect_opener).to be_nil
    end

    it 'returns the first available opener (open before xdg-open)' do
      allow(described_class).to receive(:which) { |b| b == 'open' ? 'open' : nil }

      expect(described_class.detect_opener).to eq('open')
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
