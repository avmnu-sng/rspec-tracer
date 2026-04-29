# frozen_string_literal: true

require 'rspec_tracer/tracker/file_digest'

RSpec.describe RSpecTracer::Tracker::FileDigest do
  let(:root) { Dir.mktmpdir('file_digest_spec_') }
  let(:path) { File.join(root, 'a.rb') }

  before do
    described_class.reset!
    File.write(path, "puts :one\n")
  end

  after { FileUtils.remove_entry(root) }

  describe '.compute' do
    it 'returns the SHA256 hex digest of the file content' do
      digest = described_class.compute(path)
      expect(digest).to eq(Digest::SHA256.hexdigest("puts :one\n"))
    end

    context 'when the second call sees unchanged stat' do
      it 'returns the same digest' do
        first = described_class.compute(path)
        expect(described_class.compute(path)).to eq(first)
      end

      it 'does not re-invoke Digest::SHA256.file' do
        described_class.compute(path)
        allow(Digest::SHA256).to receive(:file).and_call_original
        described_class.compute(path)
        expect(Digest::SHA256).not_to have_received(:file)
      end
    end

    context 'when the file content + size change between calls' do
      it 'returns a different digest' do
        first = described_class.compute(path)
        File.write(path, "puts :two_longer_content\n")
        expect(described_class.compute(path)).not_to eq(first)
      end

      it 'returns the digest of the new content' do
        described_class.compute(path)
        File.write(path, "puts :two_longer_content\n")
        expect(described_class.compute(path)).to eq(Digest::SHA256.hexdigest("puts :two_longer_content\n"))
      end
    end

    it 'returns nil when the file is missing (Errno::ENOENT)' do
      expect(described_class.compute(File.join(root, 'missing.rb'))).to be_nil
    end

    it 'returns nil when Digest::SHA256.file raises a SystemCallError' do
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)
      expect(described_class.compute(path)).to be_nil
    end
  end

  describe '.reset!' do
    it 'drops cached entries so subsequent calls re-digest' do
      described_class.compute(path)
      described_class.reset!
      allow(Digest::SHA256).to receive(:file).and_call_original
      described_class.compute(path)
      expect(Digest::SHA256).to have_received(:file).once
    end
  end
end
