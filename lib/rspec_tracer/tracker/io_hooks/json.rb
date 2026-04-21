# frozen_string_literal: true

module RSpecTracer
  module Tracker
    module IOHooks
      # Prepended onto JSON.singleton_class. JSON.load_file is the
      # user-level file-reading entry point; JSON.parse takes a
      # string and is not hooked here.
      module JSONReads
        def load_file(path, ...)
          IOHooks.record(path)
          super
        end
      end
    end
  end
end
