# frozen_string_literal: true

require 'spec_helper'

# Stubbing system on the subject is unavoidable here: upload_dir delegates
# to `system` on self; we verify the failure-path wording by making system
# return false.
# rubocop:disable RSpec/SubjectStub
RSpec.describe RSpecTracer::RemoteCache::Aws do
  let(:original_s3_uri) { ENV.fetch('RSPEC_TRACER_S3_URI', nil) }
  let(:original_local_aws) { ENV.fetch('LOCAL_AWS', nil) }

  before do
    ENV['RSPEC_TRACER_S3_URI'] = 's3://bucket/reports/path'
    ENV.delete('LOCAL_AWS')
  end

  after do
    ENV['RSPEC_TRACER_S3_URI'] = original_s3_uri
    ENV['LOCAL_AWS'] = original_local_aws
  end

  describe '#upload_dir — error wording' do
    subject(:aws) { described_class.new }

    let(:ref) { 'ref1' }
    let(:run_id) { 'run1' }

    before do
      FileUtils.mkdir_p(File.join(RSpecTracer.cache_path, run_id))
      allow(aws).to receive(:system).and_return(false)
    end

    after { FileUtils.rm_rf(File.join(RSpecTracer.cache_path, run_id)) }

    it 'raises AwsError with "Failed to upload" wording (C3 fix)' do
      expect { aws.upload_dir(ref, run_id) }.to raise_error(
        RSpecTracer::RemoteCache::Aws::AwsError,
        /Failed to upload files from/
      )
    end
  end
end
# rubocop:enable RSpec/SubjectStub
