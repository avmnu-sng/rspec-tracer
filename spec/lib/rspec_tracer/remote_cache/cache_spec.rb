# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Cache do
  subject(:service) { described_class.new }

  let(:aws) { instance_double(RSpecTracer::RemoteCache::Aws) }
  let(:branch_name) { 'branch' }

  before do
    allow(RSpecTracer::RemoteCache::Aws).to receive(:new) { aws }
    allow(aws).to receive(:branch_refs?).with(branch_name)
    stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_S3_URI' => 's3://bucket/folder'))
    stub_const('ENV', ENV.to_hash.merge('GIT_BRANCH' => branch_name))
  end

  after do
    ENV.delete('RSPEC_TRACER_S3_URI')
    ENV.delete('GIT_BRANCH')
  end

  describe '.download' do
    before do
      allow(aws).to receive_messages(download_file: anything, download_dir: anything)
      allow(aws).to receive(:empty_bucket?).and_return(bucket_empty?)
    end

    context 'when s3 bucket is empty' do
      let(:bucket_empty?) { true }

      it 'early returns from the method' do
        service.download
        expect(aws).not_to have_received(:download_file)
      end
    end

    context 'when s3 bucket is not empty' do
      let(:bucket_empty?) { false }

      it 'early proceeds with download' do
        allow(service).to receive(:cache_ref?).and_return(true)
        service.download
        expect(aws).to have_received(:download_file)
      end
    end
  end
end
