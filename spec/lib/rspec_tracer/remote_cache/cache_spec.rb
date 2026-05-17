# frozen_string_literal: true

require 'spec_helper'

# Coverage for the 1.2.4 remote_cache INFO-line addition. Pre-fix,
# `#download` and `#upload` returned silently after the AWS calls
# succeeded — a successful `rake rspec_tracer:remote_cache:download`
# produced zero output, leaving the user unable to tell from CI logs
# whether the cache was restored. The fix emits a single
# `RSpecTracer.logger.info` line on the success path of each operation.
#
# Cache validation, branch refs, and the underlying AWS calls are
# stubbed so the test isolates the new logger calls; the validator,
# repo, and AWS classes have their own specs alongside this one.
#
# rubocop:disable RSpec/SubjectStub
RSpec.describe RSpecTracer::RemoteCache::Cache do
  subject(:cache) { described_class.new }

  let(:aws) { instance_double(RSpecTracer::RemoteCache::Aws) }
  let(:repo) { instance_double(RSpecTracer::RemoteCache::Repo) }

  before do
    allow(RSpecTracer::RemoteCache::Aws).to receive(:new).and_return(aws)
    allow(RSpecTracer::RemoteCache::Repo).to receive(:new).with(aws).and_return(repo)
    allow(RSpecTracer.logger).to receive(:info)
  end

  describe '#download' do
    context 'when a suitable cache ref is available' do
      let(:cache_sha) { 'abc1234' }
      let(:run_id) { 'run_xyz' }

      before do
        cache.instance_variable_set(:@cache_sha, cache_sha)
        allow(cache).to receive_messages(cache_ref?: true, last_run_id: run_id)
        allow(aws).to receive(:download_file)
        allow(aws).to receive(:download_dir)
      end

      it 'logs an INFO line naming the restored cache sha' do
        cache.download

        expect(RSpecTracer.logger).to have_received(:info)
          .with("rspec-tracer remote_cache: restored cache from #{cache_sha}")
      end
    end

    context 'when no cache ref is available' do
      before { allow(cache).to receive(:cache_ref?).and_return(false) }

      it 'does not emit the restored INFO line' do
        cache.download

        expect(RSpecTracer.logger).not_to have_received(:info)
          .with(/restored cache from/)
      end
    end
  end

  describe '#upload' do
    let(:branch_ref) { 'def5678' }
    let(:branch_name) { 'main' }
    let(:run_id) { 'run_xyz' }

    before do
      allow(repo).to receive_messages(
        branch_ref: branch_ref, branch_name: branch_name, branch_refs: {}
      )
      allow(cache).to receive_messages(last_run_id: run_id, write_branch_refs: nil)
      allow(aws).to receive(:upload_file)
      allow(aws).to receive(:upload_dir)
      allow(aws).to receive(:upload_branch_refs)
    end

    it 'logs an INFO line naming the uploaded branch ref' do
      cache.upload

      expect(RSpecTracer.logger).to have_received(:info)
        .with("rspec-tracer remote_cache: uploaded cache to #{branch_ref}")
    end
  end
end
# rubocop:enable RSpec/SubjectStub
