# frozen_string_literal: true

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Internal IOHooks — see {RSpecTracer} for the user-facing surface.
    # @api private
    module IOHooks
      # Prepended onto IO.singleton_class. IO.read is the only method
      # the brief asks for here - File.read covers the bulk of the
      # use cases; IO.read exists mostly for compatibility with older
      # code paths and third-party libraries that reach through IO.
      module IOReads
        # Internal method on the tracer pipeline.
        # @api private
        def read(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end
      end
    end
  end
end
