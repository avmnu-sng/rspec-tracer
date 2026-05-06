# frozen_string_literal: true

require 'set'

require_relative 'file_digest'
require_relative 'input'

module RSpecTracer
  module Tracker
    # Observer #3 in the 2.0 tracker pipeline (CoverageAdapter = #1,
    # IOHooks = #2). Walks user-declared glob patterns at boot, digests
    # each matching file, and emits :declared Inputs. Declared globs
    # cover inputs that cannot be auto-observed - files no app code
    # reads (Gemfile.lock, .rspec-tracer), or files that might not be
    # rendered during a given run (a newly-added template).
    #
    # Exposes #covers? so IOHooks can skip paths the declared-globs
    # walk already observed. ARCHITECTURE rule (Input taxonomy): "if
    # the user declares a glob that covers the same files we auto-
    # intercept, the declared glob takes precedence."
    #
    # Graceful degradation (CLAUDE.md): an unreadable declared file is
    # skipped silently - the tracer never propagates failure into the
    # user's test suite. Identity-based Set dedup collapses overlap
    # when two globs match the same file.
    class DeclaredGlobs
      # FNM_PATHNAME keeps `*` from eating `/` so globs walk directory
      # boundaries predictably. FNM_EXTGLOB enables `{a,b}` alternation
      # so `coverage_track_files '{app,lib}/**/*.rb'` (a real pattern
      # in the sample projects) matches the same files `Dir.glob` would.
      FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

      attr_reader :root, :globs

      def initialize(root:, globs: [])
        @root = File.expand_path(root)
        @root_prefix = "#{@root}/"
        @globs = Array(globs).flatten.compact.map(&:to_s).uniq.freeze
      end

      # Memoized across calls - the architecture constraint is "glob
      # walk at boot is a single pass; result cached for the life of
      # the tracker instance."
      def walk
        @walk ||= compute_walk
      end

      # O(N_globs) per call; N is typically 1-10. Absolute paths only -
      # the callers (IOHooks precedence, NewFileDetector diff) always
      # hold absolute paths. Paths outside root never match.
      def covers?(path)
        return false if @globs.empty?
        return false unless path.start_with?(@root_prefix)

        rel = path[@root_prefix.length..]
        @globs.any? { |glob| File.fnmatch?(glob, rel, FNMATCH_FLAGS) }
      end

      # Per-example attribution. Declared inputs attach to every
      # example in the suite (per-example narrowing is available via
      # the per-example `tracks:` DSL). Each example gets its own Set
      # copy so downstream mutation of one example's input set does
      # not leak into siblings.
      def attribute_to(example_ids)
        inputs = walk
        example_ids.to_h { |id| [id, Set.new(inputs)] }
      end

      private

      def compute_walk
        @globs.each_with_object(Set.new) do |glob, acc|
          Dir.glob(glob, base: @root).each do |rel|
            abs = File.expand_path(rel, @root)
            next unless abs.start_with?(@root_prefix) && File.file?(abs)

            digest = file_digest(abs)
            next if digest.nil?

            acc << Input.for_file(path: abs, kind: :declared, digest: digest, root: @root)
          end
        end
      end

      def file_digest(path)
        FileDigest.compute(path)
      end
    end
  end
end
