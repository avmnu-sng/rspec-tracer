# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Repo do
  subject(:service) { described_class.new(aws) }

  let(:aws) { instance_double('aws') }

  describe 'initialize' do
    context 'when GIT_BRANCH is not defined' do
      it 'raises an error' do
        expect { service }
          .to raise_error(RSpecTracer::RemoteCache::Repo::RepoError)
      end
    end

    context 'when GIT_BRANCH is defined' do
      before do
        branch_name = 'some branch'
        stub_const('ENV', ENV.to_hash.merge('GIT_BRANCH' => branch_name))
        allow(aws).to receive(:branch_refs?).with(branch_name)
      end

      after { ENV.delete('GIT_BRANCH') }

      it 'does not raise an error' do
        expect { service }.not_to raise_error
      end
    end
  end
end
