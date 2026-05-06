# frozen_string_literal: true

module RSpecTracer
  # Internal Filter — see {RSpecTracer} for the user-facing surface.
  # @api private
  #
  # Internal dispatch shim for the user-facing `add_filter` /
  # `add_coverage_filter` DSL. The user passes a String / Regexp /
  # Proc / Array; `Filter.register` wraps it in the matching subclass
  # so the engine can call a uniform `#match?(source_file)`.
  class Filter
    # Internal attribute.
    # @api private
    attr_reader :filter

    # Internal helper for the tracer pipeline.
    # @api private
    def self.register(filter)
      return filter if filter.is_a?(Filter)

      filter_class(filter).new(filter)
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.filter_class(filter)
      case filter
      when String
        StringFilter
      when Regexp
        RegexFilter
      when Proc
        BlockFilter
      when Array
        ArrayFilter
      else
        raise ArgumentError, 'Unknow filter'
      end
    end

    # Internal method on the tracer pipeline.
    # @api private
    def initialize(filter)
      @filter = filter
    end

    # Internal method on the tracer pipeline.
    # @api private
    def match?(_source_file)
      raise "#{self.class.name}#match? is not intended for direct use"
    end
  end

  # Internal ArrayFilter — see {RSpecTracer} for the user-facing surface.
  # @api private
  class ArrayFilter < RSpecTracer::Filter
    # Internal method on the tracer pipeline.
    # @api private
    def initialize(filters)
      filter_list = filters.each_with_object([]) do |filter, list|
        list << Filter.register(filter)
      end

      super(filter_list)
    end

    # Internal method on the tracer pipeline.
    # @api private
    def match?(source_file)
      @filter.any? { |filter| filter.match?(source_file) }
    end
  end

  # Internal BlockFilter — see {RSpecTracer} for the user-facing surface.
  # @api private
  class BlockFilter < RSpecTracer::Filter
    # Internal method on the tracer pipeline.
    # @api private
    def match?(source_file)
      @filter.call(source_file)
    end
  end

  # Internal RegexFilter — see {RSpecTracer} for the user-facing surface.
  # @api private
  class RegexFilter < RSpecTracer::Filter
    # Internal method on the tracer pipeline.
    # @api private
    def match?(source_file)
      source_file[:file_name] =~ @filter
    end
  end

  # Internal StringFilter — see {RSpecTracer} for the user-facing surface.
  # @api private
  class StringFilter < RSpecTracer::Filter
    # Internal method on the tracer pipeline.
    # @api private
    def match?(source_file)
      source_file[:file_name].include?(@filter)
    end
  end
end
