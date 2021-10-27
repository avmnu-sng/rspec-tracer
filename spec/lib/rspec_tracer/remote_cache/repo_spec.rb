# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Repo do
  subject(:service) { described_class.new(aws) }

  let(:aws) { instance_double('aws') }

  it 'raises an error if GIT_BRANCH is not defined' do
    expect { service }
      .to raise_error(RSpecTracer::RemoteCache::Repo::RepoError)
  end

  it 'does not raise an error if GIT_BRANCH is defined' do
    allow(ENV).to receive(:[]).with('GIT_BRANCH').and_return('some branch')
    allow(aws).to receive(:branch_refs?).with(anything)
    expect { service }.not_to raise_error(RSpecTracer::RemoteCache::Repo::RepoError)
  end
end
