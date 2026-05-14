# frozen_string_literal: true

# Regression spec for the symptom originally reported in
# https://github.com/avmnu-sng/rspec-tracer/pull/72 — gems that
# programmatically define examples (rswag's `run_test!`,
# rspec-sidekiq's worker matchers, rspec-its derivations, etc.) emit
# RSpec::Core::Example instances whose `metadata[:file_path]` resolves
# to the gem's source path or to a synthesized path that doesn't
# exist on the user's disk.
#
# In 1.x the runner crashed in `register_file_dependency` because
# `SourceFile.from_path` returned `nil` for missing files and the
# downstream `[:file_name]` access raised NoMethodError. The proposed
# fork patch was a localized nil-guard.
#
# 2.0 closes this architecturally: `Example.from`
# (lib/rspec_tracer/example.rb) builds the example identity hash from
# `metadata[:file_path]` via `SourceFile.file_path` (path resolution,
# no disk check) + `SourceFile.file_name` (root-relative path
# normalization). Neither helper requires the file to exist on disk.
# The result is a deterministic identity for every example regardless
# of whether its `file_path` resolves to a real file.
#
# The example's dependency set will be empty for the gem-generated
# example (no Coverage/IO observation can attribute to a non-existent
# source file), but the run completes cleanly and the cache writes
# without error - which is the user-visible 2.0 contract.

require 'digest'
require 'json'
require 'set'

require 'rspec_tracer'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/VerifiedDoubles
RSpec.describe 'gem-generated example with phantom file_path (regression for upstream #72)' do
  let(:phantom_file_path) { '/synthesized/by/gem.rb' }
  let(:phantom_metadata) do
    {
      file_path: phantom_file_path,
      rerun_file_path: phantom_file_path,
      line_number: 1,
      shared_group_inclusion_backtrace: []
    }
  end
  let(:phantom_example_group) do
    double('ExampleGroup', description: 'GemGeneratedExamples', parent_groups: [])
  end
  let(:phantom_example) do
    double('Example',
           example_group: phantom_example_group,
           description: 'phantom-source example',
           full_description: 'GemGeneratedExamples phantom-source example',
           metadata: phantom_metadata)
  end

  describe 'Example.from with a non-existent source file' do
    it 'returns a deterministic identity hash without raising' do
      expect { RSpecTracer::Example.from(phantom_example) }.not_to raise_error
    end

    it 'returns the canonical identity-hash shape' do
      result = RSpecTracer::Example.from(phantom_example)

      expect(result).to include(
        :example_group, :description, :full_description, :shared_group,
        :file_name, :line_number, :rerun_file_name, :rerun_line_number, :example_id
      )
    end

    it 'computes a stable example_id (md5 of the identity payload)' do
      first = RSpecTracer::Example.from(phantom_example)
      second = RSpecTracer::Example.from(phantom_example)

      expect(first[:example_id]).to eq(second[:example_id])
      expect(first[:example_id]).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'normalizes the phantom path to a root-relative file_name' do
      result = RSpecTracer::Example.from(phantom_example)

      # The file_path /synthesized/by/gem.rb starts with '/' and is
      # NOT under RSpecTracer.root + the file does not exist, so
      # SourceFile.absolute_external_file? returns false. The path
      # falls through to File.expand_path under the project root,
      # then file_name strips the project-root prefix - returning
      # /synthesized/by/gem.rb verbatim.
      expect(result[:file_name]).to eq('/synthesized/by/gem.rb')
    end
  end

  describe 'SourceFile.file_path graceful degradation' do
    it 'returns a normalized path for a non-existent absolute path under root' do
      synthesized = '/synthesized/by/gem.rb'

      expect { RSpecTracer::SourceFile.file_path(synthesized) }.not_to raise_error
      expect(RSpecTracer::SourceFile.file_path(synthesized))
        .to eq(File.expand_path('synthesized/by/gem.rb', RSpecTracer.root))
    end

    it 'returns nil from from_path when the file is missing (callers must handle)' do
      # The 2.0 architecture's invariant: from_path returns nil for
      # non-existent paths so callers can decide whether to skip or
      # graceful-degrade. The 1.x runner.rb crash was a missing nil
      # guard; 2.0 has no caller of from_path that doesn't handle nil.
      expect(RSpecTracer::SourceFile.from_path('/synthesized/by/gem.rb')).to be_nil
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/VerifiedDoubles
