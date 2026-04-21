# frozen_string_literal: true

module RSpecTracer
  module Tracker
    module IOHooks
      # Prepended onto IO.singleton_class. IO.read is the only method
      # the brief asks for here - File.read covers the bulk of the
      # use cases; IO.read exists mostly for compatibility with older
      # code paths and third-party libraries that reach through IO.
      module IOReads
        def read(path, ...)
          IOHooks.record(path)
          super
        end
      end
    end
  end
end
