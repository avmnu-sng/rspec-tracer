# frozen_string_literal: true

module RSpecTracer
  module Tracker
    module IOHooks
      # Prepended onto File.singleton_class. Each method records the
      # path (IOHooks.record fast-rejects outside a bucketed example
      # and swallows any error) then forwards every argument + block
      # to super via `(...)`.
      #
      # The `if Thread.current[BUCKET_KEY]` guard is the hot-path
      # cut: FileReads sits in every File.singleton_class read on
      # the entire process for the life of the run, even between
      # examples and during boot. Without the guard each File.read
      # paid 2 method-dispatch frames + IOHooks._record's
      # @root_prefix nil-check before the inner bucket check could
      # bail. With the guard, the bucket check happens at FileReads
      # so the reject path skips IOHooks.record entirely. Cuts the
      # M2 Max reject overhead from ~530 ns/call to ~300 ns/call
      # (M3.1-M3.2 absorbed orphan).
      module FileReads
        def read(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end

        def binread(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end

        def readlines(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end

        def open(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end
      end
    end
  end
end
