# frozen_string_literal: true

require 'spec_helper'

# Stubbing methods on the subject under test is unavoidable here:
# `cache_files_list` shells out via backticks (a private Kernel method on self),
# and `upload_dir` delegates to `system` on self. We verify the intended
# command is issued by intercepting it on the subject.
# rubocop:disable RSpec/SubjectStub
RSpec.describe RSpecTracer::RemoteCache::Aws do
  subject(:aws) { described_class.new }

  let(:envs) { %w[TEST_SUITE_ID USE_TEST_SUITE_ID_CACHE] }

  before do
    envs.each { |env| ENV.delete(env) }
    allow(RSpecTracer).to receive_messages(
      reports_s3_path: 's3://bucket/reports/path',
      use_local_aws: false
    )
  end

  after { envs.each { |env| ENV.delete(env) } }

  describe '#cache_files_list' do
    let(:ref) { 'abc123' }

    context 'when USE_TEST_SUITE_ID_CACHE is unset (default)' do
      it 'shells out with the unscoped ref prefix' do
        allow(aws).to receive(:`).and_return('')
        aws.cache_files_list(ref)
        expect(aws).to have_received(:`).with('aws s3 ls s3://bucket/reports/path/abc123/ --recursive')
      end
    end

    context 'when USE_TEST_SUITE_ID_CACHE=true and TEST_SUITE_ID=3' do
      before do
        ENV['USE_TEST_SUITE_ID_CACHE'] = 'true'
        ENV['TEST_SUITE_ID']           = '3'
      end

      it 'shells out with the suite-scoped prefix' do
        allow(aws).to receive(:`).and_return('')
        aws.cache_files_list(ref)
        expect(aws).to have_received(:`).with('aws s3 ls s3://bucket/reports/path/abc123/3/ --recursive')
      end
    end

    context 'when USE_TEST_SUITE_ID_CACHE=true but TEST_SUITE_ID is unset' do
      before { ENV['USE_TEST_SUITE_ID_CACHE'] = 'true' }

      it 'falls back to the unscoped prefix (graceful — no "nil" in URL)' do
        allow(aws).to receive(:`).and_return('')
        aws.cache_files_list(ref)
        expect(aws).to have_received(:`).with('aws s3 ls s3://bucket/reports/path/abc123/ --recursive')
      end
    end
  end

  describe '#upload_dir — error wording' do
    let(:ref)    { 'ref1' }
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
