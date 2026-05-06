# frozen_string_literal: true

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Internal IOHooks — see {RSpecTracer} for the user-facing surface.
    # @api private
    module IOHooks
      # Prepended onto JSON.singleton_class. JSON.load_file is the
      # user-level file-reading entry point; JSON.parse takes a
      # string and is not hooked here.
      module JSONReads
        # Internal method on the tracer pipeline.
        # @api private
        def load_file(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end
      end
    end
  end
end
