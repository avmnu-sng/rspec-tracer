# frozen_string_literal: true

require 'set'

module RSpecTracer
  module Tracker
    # Closed taxonomy of input sources. M3.1 only produces :ruby
    # (Coverage-observed source). The other kinds are the surface for
    # M3.2 (:data via I/O hooks), M3.3 (:declared, :lockfile), M3.7
    # (:env) and later sessions. Adding a new kind is a one-line change
    # here plus a test; shrinking the set is a schema_version bump.
    ALLOWED_INPUT_KINDS = %i[
      ruby template data schema lockfile declared env notification
    ].to_set.freeze

    # Value object representing a single input to a test. A test is a
    # pure function of its inputs (see ARCHITECTURE.md); every input
    # the tracker observes becomes one Input.
    #
    # Construct via Input.for_file - it expands the absolute path,
    # validates the kind, and precomputes the stable identity string.
    # The returned struct is frozen.
    #
    # Equality, hash, and eql? key on :identity only - two Inputs with
    # the same identity but different digests are considered the same
    # input at different points in time. Freshness lives on :digest
    # and is queried via #stale?.
    #
    # Digest algorithm is caller-chosen (the observer owns content
    # hashing); 2.0's default is SHA256 hex (see CoverageAdapter).
    # Changing the algorithm is a storage schema_version bump.
    #
    # Methods are defined on the reopened class body (not the
    # Struct.new block) so mutant can introspect them via
    # Method#source_location - block-scoped defs live on an anonymous
    # singleton and mutant reports Subjects: 0 for them.
    Input = Struct.new(:path, :kind, :digest, :identity, keyword_init: true)

    class Input
      def self.for_file(path:, kind:, digest:, root:)
        unless ALLOWED_INPUT_KINDS.include?(kind)
          raise ArgumentError,
                "invalid Input kind: #{kind.inspect}; " \
                "allowed: #{ALLOWED_INPUT_KINDS.to_a.inspect}"
        end

        abs_path = File.expand_path(path)
        identity = "#{kind}:#{relative_path(abs_path, root)}"

        new(path: abs_path, kind: kind, digest: digest, identity: identity).freeze
      end

      # Strip `root/` prefix from an absolute path. When the path
      # escapes the root (absolute symlink target, vendored gem under a
      # different tree, etc.) we fall back to the full absolute path so
      # identity stays unique - the deterministic rule is "same path
      # under same root => same identity", nothing stronger.
      def self.relative_path(abs_path, root)
        root_abs = File.expand_path(root)
        prefix = "#{root_abs}/"

        return abs_path unless abs_path.start_with?(prefix)

        abs_path[prefix.length..]
      end

      # `!=` handles every case correctly: nil-vs-nil is NOT stale
      # (absent stayed absent), present-vs-nil and nil-vs-present are
      # stale (file appeared/disappeared), and digest-vs-digest is
      # stale iff the content changed.
      def stale?(current_digest)
        current_digest != digest
      end

      # Inputs are value-typed and not meant to be subclassed;
      # `instance_of?` is precise where `is_a?` would let a subclass
      # with matching identity compare equal.
      def ==(other)
        other.instance_of?(self.class) && identity == other.identity
      end

      alias eql? ==

      def hash
        identity.hash
      end
    end
  end
end
