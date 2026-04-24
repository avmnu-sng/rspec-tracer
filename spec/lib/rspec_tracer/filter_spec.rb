# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/MultipleDescribes
RSpec.describe RSpecTracer::Filter do
  describe '.register' do
    it 'returns the filter unchanged if it is already a Filter' do
      existing = RSpecTracer::StringFilter.new('/vendor/')
      expect(described_class.register(existing)).to equal(existing)
    end

    it 'wraps a String in a StringFilter' do
      expect(described_class.register('/foo/')).to be_a(RSpecTracer::StringFilter)
    end

    it 'wraps a Regexp in a RegexFilter' do
      expect(described_class.register(/foo/)).to be_a(RSpecTracer::RegexFilter)
    end

    it 'wraps a Proc in a BlockFilter' do
      expect(described_class.register(proc { |_sf| true })).to be_a(RSpecTracer::BlockFilter)
    end

    it 'wraps an Array via ArrayFilter' do
      expect(described_class.register(%w[/foo/ /bar/])).to be_a(RSpecTracer::ArrayFilter)
    end

    it 'raises ArgumentError on unsupported types' do
      expect { described_class.register(42) }.to raise_error(ArgumentError)
    end
  end
end

RSpec.describe RSpecTracer::BlockFilter do
  let(:source_file) { { file_name: '/app/foo.rb', file_path: '/abs/app/foo.rb', digest: 'abc' } }

  it 'passes the SourceFile Hash (keys :file_name, :file_path, :digest) to the block' do
    received = nil
    described_class.new(->(sf) { received = sf }).match?(source_file)
    expect(received).to eq(source_file)
  end
end

# Forward-protection: pin the configure-DSL block-delivery contract so a
# future refactor of the alias-method wrapper around `add_filter` /
# `add_coverage_filter` can't silently drop the block the way the 1.1.0
# DSL refactor did before its own B6 fix landed.
RSpec.describe 'RSpecTracer.configure block forwarding' do
  around do |example|
    previous_filters = RSpecTracer.filters.dup
    previous_coverage_filters = RSpecTracer.coverage_filters.dup
    RSpecTracer.filters = []
    RSpecTracer.coverage_filters = []
    example.run
  ensure
    RSpecTracer.filters = previous_filters
    RSpecTracer.coverage_filters = previous_coverage_filters
  end

  it 'delivers the block given to add_filter into a BlockFilter' do
    RSpecTracer.configure do
      add_filter { |source_file| source_file[:file_name].include?('vendor') }
    end

    expect(RSpecTracer.filters.last).to be_a(RSpecTracer::BlockFilter)
  end

  it 'delivers the block given to add_coverage_filter into a BlockFilter' do
    RSpecTracer.configure do
      add_coverage_filter { |file_name:| file_name.include?('spec/') }
    end

    expect(RSpecTracer.coverage_filters.last).to be_a(RSpecTracer::BlockFilter)
  end
end
# rubocop:enable RSpec/MultipleDescribes
