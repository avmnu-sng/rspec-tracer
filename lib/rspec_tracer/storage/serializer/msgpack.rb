# frozen_string_literal: true

require 'zlib'

module RSpecTracer
  # Internal Storage — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Storage
    # Internal Serializer — see {RSpecTracer} for the user-facing surface.
    # @api private
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
      #
      # Type extensions: Ruby `Time` and `Symbol` values surface in
      # example metadata (RSpec's `execution_result.started_at` is a
      # Time; status values like `:passed` / `:failed` / `:flaky` are
      # Symbols on the in-memory snapshot). The bare msgpack default
      # registry has no `Time` packer (crashes
      # `NoMethodError: undefined method 'to_msgpack'`) and silently
      # coerces `Symbol` to `String` (lossy round-trip). Both
      # behaviors broke the cache on the first run a user followed
      # the 50 MiB warning's `:msgpack` recommendation. Registering
      # `Factory` type extensions for `Time` (ID 0x00, 12-byte
      # seconds+nanoseconds payload) and `Symbol` (ID 0x01, UTF-8
      # string payload) gives lossless round-trip. The factory is
      # memoized so the extension registration is one-shot per
      # process.
      class Msgpack
        # Internal constant — `MessagePack::Factory#register_type`
        # ID for Ruby `Time`. Codepoint chosen from the user-space
        # range (0x00–0x7F per msgpack ext spec); collision-safe with
        # the built-in timestamp ext (ID -1 / 0xFF) since IDs are
        # disjoint.
        # @api private
        TIME_EXTENSION_TYPE = 0x00
        # Internal constant — `MessagePack::Factory#register_type` ID
        # for Ruby `Symbol`. See {TIME_EXTENSION_TYPE} rationale.
        # @api private
        SYMBOL_EXTENSION_TYPE = 0x01

        # Internal helper for the tracer pipeline.
        # @api private
        def self.extension
          'msgpack.gz'
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.encode(payload)
          ::Zlib::Deflate.deflate(factory.pack(payload))
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.decode(bytes)
          factory.unpack(::Zlib::Inflate.inflate(bytes))
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

          # `MessagePack::Factory` with `Time` and `Symbol` type
          # extensions registered. Memoized for the process lifetime;
          # the factory's `register_type` calls are not idempotent
          # (re-registering would double-register the codepoint), so
          # one-shot construction is the simplest correctness
          # contract.
          def factory
            return @factory if defined?(@factory) && @factory

            ensure_available!
            @factory = build_factory
          end

          # `Time` and `Symbol` packers / unpackers. Packers are
          # called by `factory.pack` whenever a Ruby `Time` /
          # `Symbol` appears at any depth in the payload (top-level
          # value, nested Hash value, Array element). Unpackers are
          # called by `factory.unpack` on the ext-typed bytes.
          # Symbol pack/unpack maps to `to_s` / `to_sym` directly
          # via `Symbol#to_proc`; Time is more involved so it gets
          # named `pack_time` / `unpack_time` helpers below.
          def build_factory
            f = ::MessagePack::Factory.new
            f.register_type(
              TIME_EXTENSION_TYPE, ::Time,
              packer: method(:pack_time),
              unpacker: method(:unpack_time)
            )
            f.register_type(
              SYMBOL_EXTENSION_TYPE, ::Symbol,
              packer: :to_s.to_proc,
              unpacker: :to_sym.to_proc
            )
            f
          end

          # Time encoding: 64-bit signed seconds (`tv_sec`) + 32-bit
          # signed nanoseconds (`tv_nsec`), little-endian, 12 bytes
          # total. Round-trip canonicalizes to UTC — rspec-tracer
          # never re-uses the Time as a user-facing wall-clock value
          # (cache entries are compared, not displayed), and UTC
          # makes the on-disk bytes timezone-independent so a cache
          # built in one tz reads back identically in another.
          def pack_time(time)
            [time.tv_sec, time.tv_nsec].pack('q<l<')
          end

          def unpack_time(data)
            sec, nsec = data.unpack('q<l<')
            ::Time.at(sec, nsec, :nanosecond).utc
          end

          # Internal method on the tracer pipeline.
          # @api private
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
