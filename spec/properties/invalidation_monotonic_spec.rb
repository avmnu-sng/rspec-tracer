# frozen_string_literal: true

# Property-test bodies legitimately need setup before the expectation;
# RSpec/ExampleLength is tuned for unit tests with a single-line body.
# rubocop:disable RSpec/ExampleLength, RSpec/DescribeClass
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rantly/rspec_extensions'
require 'rspec_tracer/tracker/declared_globs'
require 'rspec_tracer/tracker/new_file_detector'

# Fixed alphabet of files on disk - Rantly can only produce collisions
# against a small population, and collisions are the whole point of
# monotonicity testing (adding a glob that covers already-covered
# files must not shrink the Input set).
MONOTONIC_FILES = %w[
  lib/a.rb lib/nested/b.rb lib/util/c.rb
  app/x.rb app/models/y.rb
  db/schema.rb
  config/a.yml config/b.yml
].freeze

MONOTONIC_GLOBS = %w[
  lib/**/*.rb
  lib/*.rb
  app/**/*.rb
  db/schema.rb
  config/*.yml
  does/not/exist/*.rb
].freeze

module InvalidationMonotonicGen
  module_function

  def subset_of(list)
    # choose(*list) with a random count; `sample` keeps the selection
    # simple without pulling in extra Rantly combinators.
    n = Rantly { range(0, list.size) }
    list.sample(n)
  end

  def extra_glob(exclude:)
    candidates = MONOTONIC_GLOBS - exclude
    return nil if candidates.empty?

    Rantly { choose(*candidates) }
  end

  def build_walker(root, globs)
    RSpecTracer::Tracker::DeclaredGlobs.new(root: root, globs: globs)
  end
end

RSpec.describe 'invalidation monotonicity' do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  before do
    MONOTONIC_FILES.each do |rel|
      abs = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(abs))
      File.write(abs, "content:#{rel}\n")
    end
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  describe 'DeclaredGlobs#walk' do
    it 'is monotonic in the globs list (adding a glob never shrinks the Input set)' do
      property_of { InvalidationMonotonicGen.subset_of(MONOTONIC_GLOBS) }.check(100) do |globs|
        extra = InvalidationMonotonicGen.extra_glob(exclude: globs)
        next if extra.nil?

        before_inputs = InvalidationMonotonicGen.build_walker(root, globs).walk
        after_inputs = InvalidationMonotonicGen.build_walker(root, globs + [extra]).walk

        expect(after_inputs).to be >= before_inputs
      end
    end
  end

  describe 'DeclaredGlobs#covers?' do
    it 'is monotonic: a path covered by G is still covered by G + {g}' do
      property_of { InvalidationMonotonicGen.subset_of(MONOTONIC_GLOBS) }.check(100) do |globs|
        extra = InvalidationMonotonicGen.extra_glob(exclude: globs)
        next if extra.nil?

        before_walker = InvalidationMonotonicGen.build_walker(root, globs)
        after_walker = InvalidationMonotonicGen.build_walker(root, globs + [extra])

        covered_before = MONOTONIC_FILES
          .map { |rel| File.join(root, rel) }
          .select { |p| before_walker.covers?(p) }

        expect(covered_before).to all(satisfy { |p| after_walker.covers?(p) })
      end
    end
  end

  describe 'NewFileDetector#new_files' do
    it 'is monotonic in declared_globs (adding a glob never shrinks the new-files set)' do
      property_of { InvalidationMonotonicGen.subset_of(MONOTONIC_GLOBS) }.check(100) do |globs|
        extra = InvalidationMonotonicGen.extra_glob(exclude: globs)
        next if extra.nil?

        before_set = RSpecTracer::Tracker::NewFileDetector
          .new(root: root, declared_globs: globs, default_globs: [])
          .new_files(known_paths: Set.new)
        after_set = RSpecTracer::Tracker::NewFileDetector
          .new(root: root, declared_globs: globs + [extra], default_globs: [])
          .new_files(known_paths: Set.new)

        expect(after_set).to be >= before_set
      end
    end
  end

  describe 'NewFileDetector#new_files is anti-monotonic in known_paths' do
    it 'adding a path to known_paths never grows the new-files set' do
      property_of { InvalidationMonotonicGen.subset_of(MONOTONIC_FILES) }.check(100) do |known_rels|
        known_abs = known_rels.map { |rel| File.join(root, rel) }
        extra = (MONOTONIC_FILES - known_rels).sample
        next if extra.nil?

        detector = RSpecTracer::Tracker::NewFileDetector.new(
          root: root, declared_globs: MONOTONIC_GLOBS, default_globs: []
        )
        before_set = detector.new_files(known_paths: Set.new(known_abs))
        after_set = detector.new_files(known_paths: Set.new(known_abs + [File.join(root, extra)]))

        expect(before_set).to be >= after_set
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/DescribeClass
