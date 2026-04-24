# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Repo do
  subject(:repo) { described_class.new(aws) }

  let(:aws) { instance_double(RSpecTracer::RemoteCache::Aws) }
  let(:original_git_branch) { ENV.fetch('GIT_BRANCH', nil) }

  before { ENV.delete('GIT_BRANCH') }
  after  { ENV['GIT_BRANCH'] = original_git_branch }

  describe '#initialize' do
    context 'when GIT_BRANCH is not set' do
      it 'raises RepoError (not NoMethodError on nil.chomp)' do
        expect { repo }.to raise_error(
          RSpecTracer::RemoteCache::Repo::RepoError,
          'GIT_BRANCH environment variable is not set'
        )
      end
    end
  end
end
