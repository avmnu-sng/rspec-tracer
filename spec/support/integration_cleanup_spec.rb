# frozen_string_literal: true

require 'fileutils'
require 'logger'
require 'tmpdir'

require_relative 'integration_cleanup'

RSpec.describe IntegrationCleanup do
  let(:tmp) { Dir.mktmpdir('rspec_tracer_integration_cleanup_') }

  after { FileUtils.rm_rf(tmp) }

  describe '.scrub_paths!' do
    it 'removes a single existing directory tree' do
      target = File.join(tmp, 'rspec_tracer_cache')
      FileUtils.mkdir_p(File.join(target, 'run-id'))
      File.write(File.join(target, 'last_run.json'), '{}')

      described_class.scrub_paths!(target)

      expect(File).not_to exist(target)
    end

    it 'removes multiple paths in a single call' do
      a = File.join(tmp, 'a')
      b = File.join(tmp, 'b')
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)

      described_class.scrub_paths!(a, b)

      expect(File).not_to exist(a)
      expect(File).not_to exist(b)
    end

    it 'flattens nested arrays so callers can splat or pass arrays' do
      a = File.join(tmp, 'a')
      b = File.join(tmp, 'b')
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)

      described_class.scrub_paths!([a, b])

      expect(File).not_to exist(a)
      expect(File).not_to exist(b)
    end

    it 'is idempotent on already-missing paths' do
      missing = File.join(tmp, 'never-existed')

      expect { described_class.scrub_paths!(missing) }.not_to raise_error
      expect(described_class.scrub_paths!(missing)).to eq([])
    end

    it 'silently skips nil and empty entries so callers can pass lazy paths' do
      target = File.join(tmp, 'real')
      FileUtils.mkdir_p(target)

      expect { described_class.scrub_paths!(nil, '', target) }.not_to raise_error
      expect(File).not_to exist(target)
    end

    it 'returns an empty failure list on full success' do
      target = File.join(tmp, 'real')
      FileUtils.mkdir_p(target)

      expect(described_class.scrub_paths!(target)).to eq([])
    end

    it 'captures per-path exceptions and logs them via the supplied logger' do
      target = File.join(tmp, 'protected')
      FileUtils.mkdir_p(target)
      logger = instance_double(Logger)
      boom = Errno::EACCES.new('permission denied')

      allow(FileUtils).to receive(:rm_rf).and_call_original
      allow(FileUtils).to receive(:rm_rf).with(target, secure: true).and_raise(boom)
      allow(logger).to receive(:warn)

      failures = described_class.scrub_paths!(target, logger: logger)

      expect(failures).to eq([[target, boom]])
      expect(logger).to have_received(:warn)
        .with(/integration_cleanup: failed to scrub.*Errno::EACCES.*permission denied/)
    end

    it 'continues scrubbing remaining paths after a single failure' do
      a = File.join(tmp, 'a')
      b = File.join(tmp, 'b')
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)

      allow(FileUtils).to receive(:rm_rf).and_call_original
      allow(FileUtils).to receive(:rm_rf).with(a, secure: true).and_raise(Errno::EACCES, 'denied')

      described_class.scrub_paths!(a, b)

      expect(File).not_to exist(b)
    end

    it 'tolerates a missing logger and still returns the failure list' do
      target = File.join(tmp, 'protected')
      FileUtils.mkdir_p(target)

      allow(FileUtils).to receive(:rm_rf).and_call_original
      allow(FileUtils).to receive(:rm_rf).with(target, secure: true).and_raise(Errno::EACCES, 'denied')

      failures = described_class.scrub_paths!(target)

      expect(failures.map(&:first)).to eq([target])
    end
  end

  describe '.scrub_default!' do
    it 'removes every canonical subdir under root' do
      described_class::DEFAULT_SUBDIRS.each do |sub|
        FileUtils.mkdir_p(File.join(tmp, sub))
      end

      described_class.scrub_default!(tmp)

      described_class::DEFAULT_SUBDIRS.each do |sub|
        expect(File).not_to exist(File.join(tmp, sub))
      end
    end

    it 'returns an empty failure list when every subdir scrubs cleanly' do
      described_class::DEFAULT_SUBDIRS.each { |sub| FileUtils.mkdir_p(File.join(tmp, sub)) }

      expect(described_class.scrub_default!(tmp)).to eq([])
    end

    it 'is a no-op when none of the canonical subdirs exist' do
      expect { described_class.scrub_default!(tmp) }.not_to raise_error
    end
  end

  describe 'DEFAULT_SUBDIRS' do
    it 'is frozen so callers can iterate without defensive copies' do
      expect(described_class::DEFAULT_SUBDIRS).to be_frozen
    end

    it 'covers cache + coverage + report + simplecov + tmp' do
      expect(described_class::DEFAULT_SUBDIRS).to contain_exactly(
        'rspec_tracer_cache',
        'rspec_tracer_coverage',
        'rspec_tracer_report',
        'coverage',
        'tmp'
      )
    end
  end
end
