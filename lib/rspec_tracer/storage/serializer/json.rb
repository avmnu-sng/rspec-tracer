# frozen_string_literal: true

require 'json'

module RSpecTracer
  # Internal Storage — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Storage
    # Internal Serializer — see {RSpecTracer} for the user-facing surface.
    # @api private
    module Serializer
      # Default serializer for JsonBackend. Produces pretty-printed
      # JSON strings; reads tolerate binary-mode bytes by forcing
      # UTF-8 on decode (preserves the fix for example titles with
      # non-ASCII bytes on US-ASCII-defaulted filesystems).
      #
      # Class-level methods (not module_function) so mutant-rspec can
      # observe mutations through the call path; see the mutation-
      # friendly-modules memo.
      class Json
        # Internal helper for the tracer pipeline.
        # @api private
        def self.extension
          'json'
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.encode(payload)
          ::JSON.pretty_generate(payload)
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.decode(bytes)
          ::JSON.parse(bytes.dup.force_encoding('UTF-8'))
        end
      end
    end
  end
end
