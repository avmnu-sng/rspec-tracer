# frozen_string_literal: true

require 'zlib'

module RSpecTracer
  module Storage
    module Serializer
      # Raised when the caller asks for :msgpack but the msgpack gem
      # is not in the user's bundle. JsonBackend rescues at construct
      # time + falls back to the Json serializer with a warn line,
      # same optional-dep pattern the RedisBackend uses for the redis
      # gem.
      class MsgpackGemNotInstalled < StandardError; end

      # MessagePack + zlib serializer. msgpack encode is ~2x smaller
      # than pretty JSON on our representative dependency graphs;
      # zlib deflate then buys another ~5x on path-repetitive
      # payloads (dependency.json is the big one - the same path
      # string appears once per example that touched it). Combined
      # ratio matches the ~4-6x claim in remote_cache/archive.rb.
      #
      # Stdlib zlib avoids adding a second gem dep; msgpack itself is
      # the single new dev-group gem. Users who want the backend
      # add `gem 'msgpack'` to their own Gemfile per
      # USER_FACING_SURFACE.md optional-dep convention.
      #
      # The require is lazy so pure-Ruby suites that stay on :json
      # do not pay the msgpack load cost and so the LoadError path
      # is exercisable in unit specs (hide_const-based).
      class Msgpack
        def self.extension
          'msgpack.gz'
        end

        def self.encode(payload)
          ensure_available!
          ::Zlib::Deflate.deflate(::MessagePack.pack(payload))
        end

        def self.decode(bytes)
          ensure_available!
          ::MessagePack.unpack(::Zlib::Inflate.inflate(bytes))
        end

        # Probe used by JsonBackend#initialize to decide whether to
        # fall back to the Json serializer at construct time. True
        # iff `require 'msgpack'` succeeds; false when the gem is
        # missing. Idempotent without an explicit memo because Ruby's
        # `require` short-circuits via `$LOADED_FEATURES` on repeat
        # calls and `defined?(::MessagePack)` cheaply detects the
        # post-load constant. The previous @msgpack_loaded ivar memo
        # was load-bearing for mutation observability: once any prior
        # test tripped the memo, mutations on the require line were
        # observably equivalent.
        def self.available?
          ensure_available!
          true
        rescue MsgpackGemNotInstalled
          false
        end

        class << self
          private

          def ensure_available!
            return if defined?(::MessagePack)

            require 'msgpack'
          rescue ::LoadError
            raise MsgpackGemNotInstalled,
                  "msgpack gem is not installed; add `gem 'msgpack'` to your Gemfile " \
                  'to use the :msgpack serializer.'
          end
        end
      end
    end
  end
end
