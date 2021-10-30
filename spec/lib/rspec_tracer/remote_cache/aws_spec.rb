# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Aws do
  subject(:service) { described_class.new }

  before { stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_S3_URI' => 's3://bucket/folder')) }

  after { ENV.delete('RSPEC_TRACER_S3_URI') }

  describe '.empty_bucket?' do
    before do
      aws_command = %w(
        aws
        s3api
        list-objects-v2
        --bucket
        bucket
        --start-after
        folder/
        --query
        Contents[].Key
      )
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(Kernel)
        .to receive(:system)
          .with(*aws_command) { aws_command_result }
      # rubocop:enable RSpec/AnyInstance
    end

    context 'when the bucket is empty' do
      let(:aws_command_result) { nil }

      it 'returns true' do
        expect(service.empty_bucket?).to be(true)
      end
    end

    context 'when the bucket is not empty' do
      let(:aws_command_result) { ['something'] }

      it 'returns false' do
        expect(service.empty_bucket?).to be(false)
      end
    end
  end
end
