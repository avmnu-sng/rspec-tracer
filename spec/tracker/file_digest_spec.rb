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

    it 'reuses the cached digest on a second call when stat is unchanged' do
      first = described_class.compute(path)
      allow(Digest::SHA256).to receive(:file).and_call_original
      second = described_class.compute(path)
      expect(second).to eq(first)
      expect(Digest::SHA256).not_to have_received(:file)
    end

    it 'recomputes the digest when the file content + size change' do
      first = described_class.compute(path)
      File.write(path, "puts :two_longer_content\n")
      second = described_class.compute(path)
      expect(second).not_to eq(first)
      expect(second).to eq(Digest::SHA256.hexdigest("puts :two_longer_content\n"))
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
