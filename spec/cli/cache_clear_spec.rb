# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'rspec_tracer/cli/cache_clear'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::CLI::CacheClear do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer cache:clear')
      end
    end

    it 'exits 0 silently when a downstream pipe closes early (broken pipe from `| head`)' do
      broken = StringIO.new
      allow(broken).to receive(:puts).and_raise(Errno::EPIPE)
      expect(described_class.run(%w[-h], stdout: broken, stderr: stderr)).to eq(0)
      expect(stderr.string).to be_empty
    end

    it 'reports nothing-to-remove when no directories exist' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive_messages(
          cache_path: File.join(dir, 'a'), coverage_path: File.join(dir, 'b'), report_path: File.join(dir, 'c')
        )
        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('nothing to remove')
      end
    end

    it 'removes existing directories with --yes (skips confirmation)' do
      Dir.mktmpdir do |dir|
        cache = File.join(dir, 'cache')
        coverage = File.join(dir, 'coverage')
        report = File.join(dir, 'report')
        [cache, coverage, report].each { |p| FileUtils.mkdir_p(p) }
        allow(RSpecTracer).to receive_messages(cache_path: cache, coverage_path: coverage, report_path: report)

        expect(described_class.run(%w[--yes], stdout: stdout, stderr: stderr)).to eq(0)
        expect(File.directory?(cache)).to be(false)
        expect(File.directory?(coverage)).to be(false)
        expect(File.directory?(report)).to be(false)
        expect(stdout.string).to include('removed')
      end
    end

    it 'accepts every documented skip-confirmation flag form' do
      %w[--yes -y --force -f].each do |flag|
        Dir.mktmpdir do |dir|
          cache = File.join(dir, 'cache')
          coverage = File.join(dir, 'coverage')
          report = File.join(dir, 'report')
          [cache, coverage, report].each { |p| FileUtils.mkdir_p(p) }
          allow(RSpecTracer).to receive_messages(
            cache_path: cache, coverage_path: coverage, report_path: report
          )
          out = StringIO.new

          message = "flag #{flag.inspect} should skip the prompt"
          expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0), message
          expect(File.directory?(cache)).to be(false), "flag #{flag.inspect} should remove cache"
        end
      end
    end

    it 'documents both --yes and --force in the help output' do
      out = StringIO.new
      described_class.run(['--help'], stdout: out, stderr: stderr)

      expect(out.string).to include('--yes').and(include('--force'))
    end

    it 'aborts when user declines the confirmation prompt' do
      Dir.mktmpdir do |dir|
        cache = File.join(dir, 'cache')
        FileUtils.mkdir_p(cache)
        allow(RSpecTracer).to receive_messages(cache_path: cache, coverage_path: '/x', report_path: '/y')
        allow($stdin).to receive(:gets).and_return("n\n")

        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(File.directory?(cache)).to be(true)
        expect(stdout.string).to include('aborted')
      end
    end

    it 'proceeds when user confirms the prompt with y' do
      Dir.mktmpdir do |dir|
        cache = File.join(dir, 'cache')
        FileUtils.mkdir_p(cache)
        allow(RSpecTracer).to receive_messages(cache_path: cache, coverage_path: '/x', report_path: '/y')
        allow($stdin).to receive(:gets).and_return("y\n")

        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(File.directory?(cache)).to be(false)
      end
    end

    it 'rescues StandardError and returns 1' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'config boom')

      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('cache:clear:')
      expect(stderr.string).to include('boom')
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
