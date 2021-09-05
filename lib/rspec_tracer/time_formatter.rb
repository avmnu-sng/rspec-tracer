# frozen_string_literal: true

module RSpecTracer
  module TimeFormatter
    DEFAULT_PRECISION = 2
    SECONDS_PRECISION = 5

    UNITS = {
      second: 60,
      minute: 60,
      hour: 24,
      day: Float::INFINITY
    }.freeze

    module_function

    def format_time(seconds)
      return pluralize(format_duration(seconds), 'second') if seconds < 60

      formatted_duration = UNITS.each_pair.with_object([]) do |(unit, count), duration|
        next unless seconds.positive?

        seconds, remainder = seconds.divmod(count)
        remainder = format_duration(remainder)

        next if remainder.zero?

        duration << pluralize(remainder, unit)
      end

      formatted_duration.reverse.join(' ')
    end

    def format_duration(duration)
      return 0 if duration.negative?

      precision = duration < 1 ? SECONDS_PRECISION : DEFAULT_PRECISION

      format("%<duration>0.#{precision}f", duration: duration)
    end

    def pluralize(duration, unit)
      if duration == 1
        "#{duration} #{unit}"
      else
        "#{duration} #{unit}s"
      end
    end

    private_class_method :format_duration, :pluralize
  end
end
