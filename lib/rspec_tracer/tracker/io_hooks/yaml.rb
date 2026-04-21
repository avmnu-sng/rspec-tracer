# frozen_string_literal: true

module RSpecTracer
  module Tracker
    module IOHooks
      # Prepended onto YAML.singleton_class (Psych). Hooks the three
      # load_file-family entry points; Psych's internals eventually
      # call File.read but YAML.load_file is the user-level API that
      # .rspec-tracer filters target.
      module YAMLReads
        def load_file(path, ...)
          IOHooks.record(path)
          super
        end

        def safe_load_file(path, ...)
          IOHooks.record(path)
          super
        end

        def unsafe_load_file(path, ...)
          IOHooks.record(path)
          super
        end
      end
    end
  end
end
