# frozen_string_literal: true

require 'json'

module RSpecTracer
  module Storage
    module Serializer
      # Default serializer for JsonBackend. Produces pretty-printed
      # JSON strings; reads tolerate binary-mode bytes by forcing
      # UTF-8 on decode (preserves the M3.1 fix for example titles
      # with non-ASCII bytes on US-ASCII-defaulted filesystems).
      #
      # Class-level methods (not module_function) so mutant-rspec can
      # observe mutations through the call path; see the mutation-
      # friendly-modules memo.
      class Json
        def self.extension
          'json'
        end

        def self.encode(payload)
          ::JSON.pretty_generate(payload)
        end

        def self.decode(bytes)
          ::JSON.parse(bytes.dup.force_encoding('UTF-8'))
        end
      end
    end
  end
end
