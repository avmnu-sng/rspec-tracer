# frozen_string_literal: true

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Internal IOHooks — see {RSpecTracer} for the user-facing surface.
    # @api private
    module IOHooks
      # Prepended onto YAML.singleton_class (Psych). Hooks the three
      # load_file-family entry points; Psych's internals eventually
      # call File.read but YAML.load_file is the user-level API that
      # .rspec-tracer filters target.
      module YAMLReads
        # Internal method on the tracer pipeline.
        # @api private
        def load_file(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end

        # Internal method on the tracer pipeline.
        # @api private
        def safe_load_file(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end

        # Internal method on the tracer pipeline.
        # @api private
        def unsafe_load_file(path, ...)
          IOHooks.record(path) if Thread.current[BUCKET_KEY]
          super
        end
      end
    end
  end
end
