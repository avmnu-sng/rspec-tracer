# frozen_string_literal: true

module RSpecTracer
  module Tracker
    module IOHooks
      # Prepended onto File.singleton_class. Each method records the
      # path (IOHooks.record fast-rejects outside a bucketed example
      # and swallows any error) then forwards every argument + block
      # to super via `(...)`.
      module FileReads
        def read(path, ...)
          IOHooks.record(path)
          super
        end

        def binread(path, ...)
          IOHooks.record(path)
          super
        end

        def readlines(path, ...)
          IOHooks.record(path)
          super
        end

        def open(path, ...)
          IOHooks.record(path)
          super
        end
      end
    end
  end
end
