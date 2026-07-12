# frozen_string_literal: true

# Fuzz-style spec proving the storage load path is crash-proof under
# arbitrary byte corruption. 1000 iterations per the original
# acceptance criterion.
#
# Runs as RSpec (not a standalone harness like the legacy
# `spec/fuzz/cache_loader_fuzz.rb`) so it lands in `task test:property`
# and CI rather than living outside the discovery surface.
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rantly/rspec_extensions'

require 'rspec_tracer/storage/json_backend'

# Rantly's property_of block evaluates in Rantly's instance context,
# so closure-captured locals / lets aren't visible. Pull generators
# into a module and reference them from the block - the pattern
# matches spec/properties/input_identity_spec.rb.
TARGET_FUZZ_FILES = [RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME] +
  RSpecTracer::Storage::JsonBackend::FILENAMES.map { |f| "run-fuzz/#{f}" }

module JsonBackendFuzzGen
  module_function

  def target
    Rantly { choose(*TARGET_FUZZ_FILES) }
  end

  def bytes
    Rantly { sized(range(0, 4096)) { string(:ascii) } }
  end
end

RSpec.describe RSpecTracer::Storage::JsonBackend, 'fuzz corruption' do
  let(:tmp_base) { Dir.mktmpdir }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:backend) { described_class.new(cache_path: cache_path) }

  before do
    # Prime the cache so corruption has something to overwrite.
    snap = RSpecTracer::Storage::Snapshot.empty(
      schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: 'run-fuzz'
    )
    backend.save_graph(snap, schema_version: RSpecTracer::Storage::Schema::CURRENT)
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  describe '#load_graph under arbitrary byte corruption' do
    it 'never raises across 1000 random-byte overwrites of any cache file' do
      property_of { [JsonBackendFuzzGen.target, JsonBackendFuzzGen.bytes] }.check(1000) do |target, bytes|
        path = File.join(cache_path, target)
        File.binwrite(path, bytes.b) if File.file?(path)

        expect { backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT) }.not_to raise_error
      end
    end
  end
end
