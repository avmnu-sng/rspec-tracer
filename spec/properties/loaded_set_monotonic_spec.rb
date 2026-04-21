# frozen_string_literal: true

# Property-test bodies legitimately need setup before the expectation;
# RSpec/ExampleLength is tuned for unit tests with a single-line body.
# rubocop:disable RSpec/ExampleLength, RSpec/DescribeClass
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rantly/rspec_extensions'
require 'rspec_tracer/tracker/loaded_files_tracker'

# Fixed alphabet of project-root paths. Rantly permutes the "peek
# sequences" returned per example - the property is that @loaded_set
# (the tracker's append-only set) only ever grows across stop_example
# calls, regardless of the order or repetition of files reported.
MONOTONIC_LOADED_FILES = %w[
  lib/a.rb lib/b.rb lib/nested/c.rb
  lib/util/d.rb lib/util/e.rb
  spec/support/f.rb
].freeze

module LoadedSetMonotonicGen
  module_function

  # Rantly generator for a sub-list of MONOTONIC_LOADED_FILES in random
  # order, with some repetition allowed - simulates Coverage reporting
  # the same keys across consecutive peeks plus new entries trickling
  # in as lazy requires fire.
  def peek_sample
    size = Rantly { range(0, MONOTONIC_LOADED_FILES.size) }
    MONOTONIC_LOADED_FILES.sample(size)
  end

  def peek_sequence(length)
    Array.new(length) { peek_sample }
  end
end

RSpec.describe 'LoadedFilesTracker monotonicity' do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  before do
    MONOTONIC_LOADED_FILES.each do |rel|
      abs = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(abs))
      File.write(abs, "content:#{rel}\n")
    end
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def abs_paths(rel_list)
    rel_list.map { |rel| File.join(root, rel) }
  end

  describe 'stop_example' do
    it 'only grows @loaded_set: after N calls, every prior snapshot is a subset of the current one' do
      property_of { LoadedSetMonotonicGen.peek_sequence(5) }.check(500) do |rels_sequence|
        peek_sequence = rels_sequence.map { |rels| abs_paths(rels) }
        tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
          root: root, peek: -> { peek_sequence.shift || [] }
        )
        tracker.capture_boot_set!

        snapshots = []
        5.times do |i|
          tracker.stop_example("ex#{i}")
          snapshots << tracker.loaded_set
        end

        snapshots.each_cons(2) { |before, after| expect(after).to be >= before }
      end
    end

    it 'loaded_set_size is non-decreasing across consecutive stop_example calls' do
      property_of { LoadedSetMonotonicGen.peek_sequence(4) }.check(500) do |rels_sequence|
        peek_sequence = rels_sequence.map { |rels| abs_paths(rels) }
        tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
          root: root, peek: -> { peek_sequence.shift || [] }
        )
        tracker.capture_boot_set!

        sizes = [tracker.loaded_set_size]
        4.times do |i|
          tracker.stop_example("ex#{i}")
          sizes << tracker.loaded_set_size
        end

        sizes.each_cons(2) { |before, after| expect(after).to be >= before }
      end
    end

    it 'returned new_inputs are disjoint from @loaded_set-before-the-call' do
      property_of { LoadedSetMonotonicGen.peek_sequence(3) }.check(500) do |rels_sequence|
        peek_sequence = rels_sequence.map { |rels| abs_paths(rels) }
        tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
          root: root, peek: -> { peek_sequence.shift || [] }
        )
        tracker.capture_boot_set!

        3.times do |i|
          before_paths = tracker.loaded_set
          new_inputs = tracker.stop_example("ex#{i}")
          # Every returned Input is a NEW observation - not already in
          # the loaded_set before this stop_example call fired.
          expect(new_inputs.map(&:path)).to all(satisfy { |p| !before_paths.include?(p) })
        end
      end
    end
  end

  describe 'loaded_set_inputs' do
    it 'is monotonic in inclusion across a sequence of stop_example calls' do
      property_of { LoadedSetMonotonicGen.peek_sequence(4) }.check(500) do |rels_sequence|
        peek_sequence = rels_sequence.map { |rels| abs_paths(rels) }
        tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
          root: root, peek: -> { peek_sequence.shift || [] }
        )
        tracker.capture_boot_set!

        snapshots = [tracker.loaded_set_inputs]
        4.times do |i|
          tracker.stop_example("ex#{i}")
          snapshots << tracker.loaded_set_inputs
        end

        snapshots.each_cons(2) { |before, after| expect(after).to be >= before }
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/DescribeClass
