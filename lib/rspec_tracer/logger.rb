# frozen_string_literal: true

module RSpecTracer
  # Internal Logger — see {RSpecTracer} for the user-facing surface.
  # @api private
  #
  # Internal logger; thin wrapper around `puts` gated on numeric log
  # level. Exposed via `RSpecTracer.logger`.
  class Logger
    # Internal method on the tracer pipeline.
    # @api private
    def initialize(log_level)
      @log_level = log_level
    end

    # Internal method on the tracer pipeline.
    # @api private
    def debug(message)
      puts message if @log_level == 1
    end

    # Internal method on the tracer pipeline.
    # @api private
    def info(message)
      puts message if @log_level.between?(1, 2)
    end

    # Internal method on the tracer pipeline.
    # @api private
    def warn(message)
      puts message if @log_level.between?(1, 3)
    end

    # Internal method on the tracer pipeline.
    # @api private
    def error(message)
      puts message if @log_level.between?(1, 4)
    end
  end
end
