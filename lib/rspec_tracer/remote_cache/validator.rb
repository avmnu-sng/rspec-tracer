# frozen_string_literal: true

require 'json'

require_relative '../storage/schema'

module RSpecTracer
  module RemoteCache
    # Cache validator. Replaces 1.x's CACHE_FILES_PER_TEST_SUITE=11
    # file-count check, which broke under any FILENAMES change (v2
    # grew from 11 to 15 files across Phase 3-6, so the old validator
    # refused every v2 cache).
    #
    # New signal: `schema_version` in `last_run.json`. The storage
    # backend writes `Storage::Schema::CURRENT` on every save; this
    # validator accepts only `Storage::Schema::SUPPORTED` values. Same
    # policy as `Storage::JsonBackend#load_graph`: mismatch means "cold
    # run," no migrators, one free cold run on upgrade.
    #
    # Atomicity note: `last_run.json` is written last via tmp+rename
    # (see `Storage::JsonBackend#write_last_run_atomic`). If
    # `last_run.json` exists, every other file in the run was present
    # at write time. So the file-count sanity check 1.x did was already
    # redundant with the atomicity guarantee; we drop it cleanly.
    module Validator
      # True when the given parsed last_run manifest is acceptable to
      # this tracer version. Missing / unparseable / wrong-shape inputs
      # all return false without raising.
      def self.valid?(manifest)
        return false unless manifest.is_a?(Hash)

        RSpecTracer::Storage::Schema.supported?(manifest['schema_version'])
      end

      # Read + parse + validate a last_run.json file on disk. Returns
      # true iff the file exists, parses as JSON, has a Hash root, and
      # carries a supported schema_version. Any I/O or parse failure
      # returns false (graceful degradation).
      def self.valid_file?(path)
        return false unless File.file?(path)

        valid?(JSON.parse(File.read(path, encoding: 'UTF-8')))
      rescue StandardError
        false
      end
    end
  end
end
