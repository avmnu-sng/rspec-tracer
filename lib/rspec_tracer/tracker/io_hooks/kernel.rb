# frozen_string_literal: true

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Internal IOHooks — see {RSpecTracer} for the user-facing surface.
    # @api private
    module IOHooks
      # Prepended onto both Kernel and Kernel.singleton_class so both
      # implicit `load 'x.rb'` (method-lookup via Object's ancestor
      # chain) and explicit `Kernel.load('x.rb')` (singleton dispatch)
      # fire the hook. Records as :ruby - CoverageAdapter also sees
      # these files through the Coverage module's load-path
      # instrumentation; the example registry dedupes the overlap.
      module KernelReads
        # Internal method on the tracer pipeline.
        # @api private
        def load(path, ...)
          IOHooks.record_ruby_load(path) if Thread.current[BUCKET_KEY]
          super
        end
      end
    end
  end
end
