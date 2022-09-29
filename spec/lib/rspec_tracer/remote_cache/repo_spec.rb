# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Repo do
  subject(:service) { described_class.new(aws) }

  let(:aws) { instance_double('aws') }

  describe '#initialize' do
    let(:envs) { %w[GIT_DEFAULT_BRANCH GIT_BRANCH] }

    before { envs.each { |env| ENV.delete(env) } }

    after { envs.each { |env| ENV.delete(env) } }

    context 'when environment variables not defined' do
      it 'raises error' do
        expect { service }.to raise_error(RSpecTracer::RemoteCache::Repo::RepoError)
      end
    end

    context 'when environment variables defined' do
      let(:branch_name) { 'a_branch' }

      before do
        envs.each { |env| ENV[env] = branch_name }

        allow(aws).to receive(:branch_refs?).with(branch_name)
      end

      it 'does not raise error' do
        expect { service }.not_to raise_error
      end
    end
  end
end
