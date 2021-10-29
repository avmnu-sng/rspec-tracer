# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Aws do
  subject(:service) { described_class.new }

  before { stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_S3_URI' => 's3://bucket/folder')) }

  after { ENV.delete('RSPEC_TRACER_S3_URI') }

  describe 'initialize' do
    context 'when RSPEC_TRACER_AWS_PROFILE is not enabled' do
      it 'does not add a profile param to the aws_cli instance variable' do
        expect(service.instance_variable_get(:@aws_cli)).to eq('aws')
      end
    end

    context 'when RSPEC_TRACER_AWS_PROFILE is enabled' do
      before { stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_AWS_PROFILE' => 'aws-profile')) }

      after { ENV.delete('RSPEC_TRACER_AWS_PROFILE') }

      it 'add a profile param to the aws_cli instance variable' do
        expect(service.instance_variable_get(:@aws_cli)).to eq('aws --profile=$RSPEC_TRACER_AWS_PROFILE')
      end
    end
  end
end
