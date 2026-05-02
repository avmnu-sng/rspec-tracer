# frozen_string_literal: true

require 'rspec_tracer/remote_cache/backend'

# Shared-examples contract for RSpecTracer::RemoteCache::Backend
# implementations. Each backend's unit spec includes these examples
# with `include_examples 'a RemoteCache::Backend'` after binding:
#
#   let(:backend) { described_class.new(...) }
#
# The contract asserts structural conformance (respond_to every
# protocol method + Backend.conforms?) plus the graceful-edge-case
# behaviors every backend must share without needing a real storage
# target - nil inputs, empty inputs, no-op retention.
#
# Round-trip assertions (upload then download, branch_refs round-trip,
# retention prune) live in `spec/integration/remote_cache_spec.rb`
# where a real storage target (localstack) is available.
RSpec.shared_examples 'a RemoteCache::Backend' do
  describe 'required methods' do
    RSpecTracer::RemoteCache::Backend::REQUIRED_METHODS.each do |method|
      it "responds to :#{method}" do
        expect(backend).to respond_to(method)
      end
    end

    it 'passes Backend.conforms?' do
      expect(RSpecTracer::RemoteCache::Backend.conforms?(backend)).to be(true)
    end
  end

  describe '#download' do
    it 'returns false for nil ref without touching storage' do
      expect(backend.download(nil)).to be(false)
    end

    it 'returns false for empty-string ref without touching storage' do
      expect(backend.download('')).to be(false)
    end

    it 'accepts a tree_sha: kwarg without raising' do
      expect { backend.download(nil, tree_sha: nil) }.not_to raise_error
    end

    it 'accepts a tree_sha: kwarg with a value without raising' do
      expect { backend.download(nil, tree_sha: 'abc123') }.not_to raise_error
    end
  end

  describe '#branch_refs' do
    it 'returns {} for nil branch_name' do
      expect(backend.branch_refs(nil)).to eq({})
    end

    it 'returns {} for empty-string branch_name' do
      expect(backend.branch_refs('')).to eq({})
    end
  end

  describe '#write_branch_refs' do
    it 'is a no-op for nil branch_name' do
      expect { backend.write_branch_refs(nil, { 'sha' => 123 }) }.not_to raise_error
    end

    it 'is a no-op for empty-string branch_name' do
      expect { backend.write_branch_refs('', { 'sha' => 123 }) }.not_to raise_error
    end

    it 'is a no-op for empty refs hash' do
      expect { backend.write_branch_refs('any-branch', {}) }.not_to raise_error
    end
  end

  describe '#prune!' do
    it 'returns 0 when no retention knob is set' do
      expect(backend.prune!).to eq(0)
    end

    it 'returns 0 when all retention knobs are nil' do
      expect(backend.prune!(count: nil, duration_seconds: nil, pr_branch_ttl_seconds: nil)).to eq(0)
    end

    it 'returns 0 when retention knobs are zero or negative' do
      expect(backend.prune!(count: 0, duration_seconds: 0, pr_branch_ttl_seconds: 0)).to eq(0)
    end
  end

  describe '#prune_all!' do
    it 'returns 0 when pr_branch_ttl_seconds is nil' do
      expect(backend.prune_all!(pr_branch_ttl_seconds: nil)).to eq(0)
    end

    it 'returns 0 when pr_branch_ttl_seconds is zero' do
      expect(backend.prune_all!(pr_branch_ttl_seconds: 0)).to eq(0)
    end

    it 'returns 0 when pr_branch_ttl_seconds is negative' do
      expect(backend.prune_all!(pr_branch_ttl_seconds: -1)).to eq(0)
    end

    it 'accepts a bare call (no kwargs) without raising' do
      expect { backend.prune_all! }.not_to raise_error
    end
  end
end
