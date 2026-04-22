# frozen_string_literal: true

# Property: Metadata.tracks_for unions each ancestor group's
# `tracks:` hash with the leaf example's own, for both :files and
# :env. No key is ever lost; no group's contribution is clobbered
# by a descendant (unlike RSpec's default metadata cascade which
# replaces on conflict).
#
# Generators run 200 iterations over randomly-built N-deep group
# trees, each ancestor optionally carrying a random mix of
# file-globs and env-names. Assertion checks that the walker output
# equals the exact set-union across the walked path.
#
# rubocop:disable RSpec/ExampleLength, RSpec/DescribeClass, RSpec/MultipleExpectations
require 'set'
require 'rantly/rspec_extensions'
require 'rspec_tracer/rspec/metadata'

PROPERTY_FILES_POOL = %w[
  app/**/*.rb config/**/*.yml lib/tasks/*.rake db/schema.rb
  app/policies/**/*.rb app/helpers/*.rb
].freeze
PROPERTY_ENVS_POOL = %w[API_KEY ROLE_CONFIG FEATURE_FLAG RAILS_ENV DATABASE_URL].freeze

module MetadataCascadeGen
  module_function

  # Produce a random `tracks:` hash OR nil. `:files` and `:env` are
  # each independently absent / singular / array - mirrors the real
  # user surface shape.
  def random_tracks(rantly)
    return nil if rantly.boolean

    hash = {}
    hash[:files] = pick_value(rantly, PROPERTY_FILES_POOL)
    hash[:env] = pick_value(rantly, PROPERTY_ENVS_POOL)
    hash.reject { |_, v| v.nil? }
  end

  def pick_value(rantly, pool)
    roll = rantly.range(0, 3)
    case roll
    when 0 then nil
    when 1 then pool.sample
    else
      count = rantly.range(1, 3)
      pool.sample(count)
    end
  end

  # Build an N-depth example with an ancestor chain; each group
  # carries its own random `tracks:` metadata.
  def build_example(rantly)
    depth = rantly.range(1, 4)
    ancestors = Array.new(depth) { build_group(rantly) }
    example_tracks = random_tracks(rantly)

    MetadataCascadeFakes::FakeExample.new(
      MetadataCascadeFakes::FakeGroup.new(ancestors, example_tracks)
    )
  end

  def build_group(rantly)
    MetadataCascadeFakes::FakeGroup.new([], random_tracks(rantly))
  end
end

# Minimal doubles for the walker - `example.example_group.parent_groups`
# and `group.metadata[:tracks]` are the only surfaces used.
module MetadataCascadeFakes
  FakeGroup = Struct.new(:parent_groups, :tracks_value) do
    def metadata
      { tracks: tracks_value }
    end
  end

  FakeExample = Struct.new(:example_group) do
    def metadata
      { tracks: example_group.tracks_value }
    end
  end
end

RSpec.describe 'RSpecTracer::RSpec::Metadata cascade invariants' do
  # Expected union computed independently - same normalization as
  # the walker uses (String => [String], Array => flattened strings,
  # empty/nil filtered).
  def normalize_expected(value)
    case value
    when String then value.empty? ? [] : [value]
    when Array then value.map(&:to_s).reject(&:empty?)
    else []
    end
  end

  def expected_union(example)
    files = Set.new
    envs = Set.new
    ancestors = example.example_group.parent_groups
    ancestors.each do |group|
      tracks = group.metadata[:tracks]
      next unless tracks.is_a?(Hash)

      normalize_expected(tracks[:files]).each { |v| files << v }
      normalize_expected(tracks[:env]).each { |v| envs << v }
    end
    leaf = example.metadata[:tracks]
    if leaf.is_a?(Hash)
      normalize_expected(leaf[:files]).each { |v| files << v }
      normalize_expected(leaf[:env]).each { |v| envs << v }
    end
    { files: files, env: envs }
  end

  it 'unions :files across every ancestor plus the leaf' do
    property_of { MetadataCascadeGen.build_example(self) }.check(200) do |example|
      expected = expected_union(example)
      actual = RSpecTracer::RSpec::Metadata.tracks_for(example)

      expect(actual[:files]).to eq(expected[:files])
    end
  end

  it 'unions :env across every ancestor plus the leaf' do
    property_of { MetadataCascadeGen.build_example(self) }.check(200) do |example|
      expected = expected_union(example)
      actual = RSpecTracer::RSpec::Metadata.tracks_for(example)

      expect(actual[:env]).to eq(expected[:env])
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/DescribeClass, RSpec/MultipleExpectations
