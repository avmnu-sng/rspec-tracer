# frozen_string_literal: true

require 'spec_helper'

require 'rspec_tracer/remote_cache/backend'

# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer::RemoteCache::Backend do
  describe 'REQUIRED_METHODS' do
    it 'is frozen' do
      expect(described_class::REQUIRED_METHODS).to be_frozen
    end

    it 'lists the protocol methods' do
      expect(described_class::REQUIRED_METHODS).to match_array(%i[
        download upload branch_refs write_branch_refs prune!
      ])
    end
  end

  describe '.conforms?' do
    it 'returns true for an object responding to every required method' do
      conformer = Class.new do
        def download(_ref); end
        def upload(_ref); end
        def branch_refs(_name); end
        def write_branch_refs(_name, _refs); end
        def prune!(**_opts); end
      end.new

      expect(described_class.conforms?(conformer)).to be(true)
    end

    it 'returns false when any required method is missing' do
      partial = Class.new do
        def download(_ref); end
        def upload(_ref); end
        # missing branch_refs, write_branch_refs, prune!
      end.new

      expect(described_class.conforms?(partial)).to be(false)
    end

    it 'returns false for a plain object' do
      expect(described_class.conforms?(Object.new)).to be(false)
    end
  end
end
# rubocop:enable RSpec/ExampleLength
