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

RSpec.describe RSpecTracer::StringFilter do
  # StringFilter uses `source_file[:file_name].include?(@filter)` — a naive
  # substring match. These specs lock in the boundary behavior so a future
  # widening (e.g. dropping a trailing slash) doesn't silently start
  # filtering user files that happen to share a prefix with rspec-tracer's
  # own paths.

  def match?(filter, file_name)
    described_class.new(filter).match?(file_name: file_name)
  end

  describe 'default-config entries' do
    it 'filters the gem entry file via /lib/rspec_tracer.rb' do
      expect(match?('/lib/rspec_tracer.rb', '/app/lib/rspec_tracer.rb')).to be(true)
    end

    it 'filters gem subdir files via /lib/rspec_tracer/' do
      expect(match?('/lib/rspec_tracer/', '/app/lib/rspec_tracer/cache.rb')).to be(true)
    end

    it 'does NOT filter user files sharing the prefix', :aggregate_failures do
      # The trailing slash / .rb extension boundary is load-bearing.
      expect(match?('/lib/rspec_tracer/', '/app/lib/rspec_tracer_custom.rb')).to be(false)
      expect(match?('/lib/rspec_tracer.rb', '/app/lib/rspec_tracer_ext/foo.rb')).to be(false)
      expect(match?('/lib/rspec_tracer/', '/tmp/lib/rspec_tracer_helper.rb')).to be(false)
    end

    it 'filters rbenv / asdf / rvm install paths', :aggregate_failures do
      expect(match?('/.rbenv/versions/', '/home/u/.rbenv/versions/3.3.0/lib/ruby/json.rb')).to be(true)
      expect(match?('/.asdf/installs/ruby/', '/home/u/.asdf/installs/ruby/3.3.0/json.rb')).to be(true)
      expect(match?('/.rvm/', '/home/u/.rvm/gems/ruby-3.3.0/gems/json/json.rb')).to be(true)
    end

    it 'filters hosted-toolcache + system ruby paths', :aggregate_failures do
      expect(match?('/opt/hostedtoolcache/', '/opt/hostedtoolcache/Ruby/3.3.0/lib/ruby/json.rb')).to be(true)
      expect(match?('/usr/local/lib/ruby/', '/usr/local/lib/ruby/3.3.0/json.rb')).to be(true)
      expect(match?('/usr/local/bundle/', '/usr/local/bundle/gems/json-2.7.0/lib/json.rb')).to be(true)
    end

    it 'filters vendor/bundle' do
      expect(match?('/vendor/bundle/', '/app/vendor/bundle/ruby/3.3.0/gems/foo/lib/foo.rb')).to be(true)
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
# rubocop:enable RSpec/MultipleDescribes
