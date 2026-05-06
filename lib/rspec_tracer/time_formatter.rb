# frozen_string_literal: true

module RSpecTracer
  # Internal TimeFormatter — see {RSpecTracer} for the user-facing surface.
  # @api private
  #
  # Internal helper for human-friendly elapsed-time formatting in
  # tracer log lines and the terminal reporter (e.g. "1 minute 23 seconds").
  module TimeFormatter
    # Internal constant.
    # @api private
    DEFAULT_PRECISION = 2
    # Internal constant.
    # @api private
    SECONDS_PRECISION = 5

    # Internal constant.
    # @api private
    UNITS = {
      second: 60,
      minute: 60,
      hour: 24,
      day: Float::INFINITY
    }.freeze

    # Internal helper for the tracer pipeline.
    # @api private
    def self.format_time(seconds)
      return pluralize(format_duration(seconds), 'second') if seconds < 60

      formatted_duration = UNITS.each_pair.with_object([]) do |(unit, count), duration|
        next unless seconds.positive?

        seconds, remainder = seconds.divmod(count)

        next if remainder.zero?

        duration << pluralize(format_duration(remainder), unit)
      end

      formatted_duration.reverse.join(' ')
    end

    class << self
      private

      # Internal method on the tracer pipeline.
      # @api private
      def format_duration(duration)
        return 0 if duration.negative?

        precision = duration < 1 ? SECONDS_PRECISION : DEFAULT_PRECISION

        strip_trailing_zeroes(format("%<duration>0.#{precision}f", duration: duration))
      end

      # Internal method on the tracer pipeline.
      # @api private
      def strip_trailing_zeroes(formatted_duration)
        formatted_duration.sub(/(?:(\..*[^0])0+|\.0+)$/, '\1')
      end

      # Internal method on the tracer pipeline.
      # @api private
      def pluralize(duration, unit)
        if (duration.to_f - 1).abs < Float::EPSILON
          "#{duration} #{unit}"
        else
          "#{duration} #{unit}s"
        end
      end
    end
  end
end
