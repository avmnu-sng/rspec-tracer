# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for #188 partial — `Cache#download` /
# `#upload` previously returned silently on success, so a successful
# `rake rspec_tracer:remote_cache:*` produced zero output and users
# couldn't tell from CI logs whether the cache restored / uploaded.
#
# Stubbing private methods on the subject (cache_ref?, last_run_id,
# write_branch_refs) is unavoidable here: those private helpers do
# real I/O (S3 calls, disk reads) that the success-path INFO line
# tests should not exercise. Same convention as aws_spec.rb.
# rubocop:disable RSpec/SubjectStub
RSpec.describe RSpecTracer::RemoteCache::Cache do
  subject(:cache) { described_class.new }

  let(:aws) { instance_double(RSpecTracer::RemoteCache::Aws) }
  let(:repo) { instance_double(RSpecTracer::RemoteCache::Repo) }

  before do
    allow(RSpecTracer::RemoteCache::Aws).to receive(:new).and_return(aws)
    allow(RSpecTracer::RemoteCache::Repo).to receive(:new).with(aws).and_return(repo)
  end

  describe '#download' do
    let(:cache_sha) { 'abc123' }
    let(:run_id) { 'run-xyz' }

    before do
      cache.instance_variable_set(:@cache_sha, cache_sha)
      allow(cache).to receive_messages(cache_ref?: true, last_run_id: run_id)
      allow(aws).to receive(:download_file)
      allow(aws).to receive(:download_dir)
    end

    it 'emits "restored cache from <sha>" on success' do
      expect { cache.download }.to output(
        /rspec-tracer remote_cache: restored cache from #{cache_sha}/
      ).to_stdout
    end
  end

  describe '#upload' do
    let(:branch_ref) { 'main-sha-abc' }
    let(:run_id) { 'run-xyz' }
    let(:branch_name) { 'main' }

    before do
      allow(repo).to receive_messages(
        branch_ref: branch_ref, branch_name: branch_name, branch_refs: {}.freeze
      )
      allow(aws).to receive(:upload_file)
      allow(aws).to receive(:upload_dir)
      allow(aws).to receive(:upload_branch_refs)
      allow(cache).to receive_messages(last_run_id: run_id, write_branch_refs: nil)
    end

    it 'emits "uploaded cache to <ref>" on success' do
      expect { cache.upload }.to output(
        /rspec-tracer remote_cache: uploaded cache to #{branch_ref}/
      ).to_stdout
    end
  end
end
# rubocop:enable RSpec/SubjectStub
