# frozen_string_literal: true

module RSpecTracer
  # Internal Logger — see {RSpecTracer} for the user-facing surface.
  # @api private
  #
  # Internal logger; thin wrapper around `IO#puts` gated on numeric
  # log level. Exposed via `RSpecTracer.logger`.
  class Logger
    class << self
      # Process-wide default destination for loggers constructed
      # without an explicit `out:`. `nil` (the norm) means `$stdout`,
      # which normal `rspec` runs rely on. The `rspec-tracer` binary
      # sets this to its stderr BEFORE booting the tracer library, so
      # loggers constructed while the project's `.rspec-tracer` config
      # loads (e.g. by the 1.x deprecation shims, or recreated after a
      # config `log_level` call resets the memoized instance) already
      # bind to stderr and machine-readable stdout (`blast-radius
      # --json`) stays free of diagnostics. See {RSpecTracer::CLI}.
      #
      # @return [IO, nil]
      # @api private
      attr_accessor :default_out
    end

    # @param log_level [Integer] numeric level (Configuration::LOG_LEVEL)
    # @param out [IO, nil] destination stream. Falls back to
    #   {Logger.default_out} when nil, then to `$stdout`.
    # @api private
    def initialize(log_level, out: nil)
      @log_level = log_level
      @out = out || self.class.default_out || $stdout
    end

    # Internal method on the tracer pipeline.
    # @api private
    def debug(message)
      @out.puts message if @log_level == 1
    end

    # Internal method on the tracer pipeline.
    # @api private
    def info(message)
      @out.puts message if @log_level.between?(1, 2)
    end

    # Internal method on the tracer pipeline.
    # @api private
    def warn(message)
      @out.puts message if @log_level.between?(1, 3)
    end

    # Internal method on the tracer pipeline.
    # @api private
    def error(message)
      @out.puts message if @log_level.between?(1, 4)
    end
  end
end
