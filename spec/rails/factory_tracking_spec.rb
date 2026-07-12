# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'

require 'rspec_tracer/rails/preset'
require 'rspec_tracer/tracker/declared_globs'
require 'rspec_tracer/tracker/loaded_files_tracker'

# Regression spec for the factory blind-spot. Factory
# files live under `spec/factories/**/*.rb` and are plain Ruby, so they
# ride two tracker pipes:
#
#   1. Preset `:factories` globs into DeclaredGlobs, so changes re-run
#      every example (conservative suite-wide signal).
#   2. If a factory is actually required during an example, Coverage
#      records it and LoadedFilesTracker attributes it as a :ruby input.
#
# This spec does not introduce a new lib file - it documents and
# asserts that the existing mechanisms see factory files on mutation,
# so the factory-file path is mechanically verifiable end-to-end.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe 'Factory tracking regression' do
  let(:tmpdir) { Dir.mktmpdir('rspec-tracer-factory') }
  let(:factory_path) { File.join(tmpdir, 'spec/factories/users.rb') }

  before do
    FileUtils.mkdir_p(File.dirname(factory_path))
    File.write(factory_path, <<~RUBY)
      FactoryBot.define do
        factory :user do
          email { 'user@example.com' }
        end
      end
    RUBY
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  describe 'via DeclaredGlobs + Preset :factories' do
    it 'enumerates the factory file with kind :declared' do
      globs = RSpecTracer::Rails::Preset::DEFAULTS[:factories]
      declared = RSpecTracer::Tracker::DeclaredGlobs.new(root: tmpdir, globs: globs)

      inputs = declared.walk

      expect(inputs.map(&:path)).to include(File.expand_path(factory_path))
    end

    it 'emits a digest that flips when the factory contents change' do
      globs = RSpecTracer::Rails::Preset::DEFAULTS[:factories]
      declared_before = RSpecTracer::Tracker::DeclaredGlobs.new(root: tmpdir, globs: globs)
      input_before = declared_before.walk.find { |i| i.path == File.expand_path(factory_path) }

      File.write(factory_path, "FactoryBot.define { factory :user do; email { 'changed@example.com' }; end }\n")
      declared_after = RSpecTracer::Tracker::DeclaredGlobs.new(root: tmpdir, globs: globs)
      input_after = declared_after.walk.find { |i| i.path == File.expand_path(factory_path) }

      expect(input_after.digest).not_to eq(input_before.digest)
    end
  end

  describe 'via LoadedFilesTracker attribution' do
    let(:peek_result) { { factory_path => [1, 1, 1, 1] } }
    let(:tracker) do
      RSpecTracer::Tracker::LoadedFilesTracker.new(
        root: tmpdir, peek: -> { peek_result.keys }
      )
    end

    it 'captures the factory file in the boot set when loaded before the first example' do
      tracker.capture_boot_set!

      expect(tracker.boot_set).to include(factory_path)
    end

    it 'emits the factory file as a :ruby Input' do
      tracker.capture_boot_set!

      input = tracker.loaded_set_inputs.find { |i| i.path == factory_path }
      expect(input.kind).to eq(:ruby)
    end

    it 'updates the boot_set digest when the factory content changes' do
      tracker.capture_boot_set!
      digest_before = tracker.boot_set_digest_snapshot.values.first

      File.write(factory_path, "# changed\n")
      fresh = RSpecTracer::Tracker::LoadedFilesTracker.new(
        root: tmpdir, peek: -> { peek_result.keys }
      )
      fresh.capture_boot_set!

      expect(fresh.boot_set_digest_snapshot.values.first).not_to eq(digest_before)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
