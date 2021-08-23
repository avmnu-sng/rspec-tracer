# frozen_string_literal: true

module RSpecTracer
  class Filter
    attr_reader :filter

    def initialize(filter)
      @filter = filter
    end

    def match?(_source_file)
      raise "#{self.class.name}#match? is not intended for direct use"
    end

    def self.register(filter)
      return filter if filter.is_a?(Filter)

      filter_class(filter).new(filter)
    end

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
  end

  class ArrayFilter < RSpecTracer::Filter
    def initialize(filters)
      filter_list = filters.each_with_object([]) do |filter, list|
        list << Filter.register(filter)
      end

      super(filter_list)
    end

    def match?(source_file)
      @filter.any? { |filter| filter.match?(source_file) }
    end
  end

  class BlockFilter < RSpecTracer::Filter
    def match?(source_file)
      @filter.call(source_file)
    end
  end

  class RegexFilter < RSpecTracer::Filter
    def match?(source_file)
      source_file[:file_name] =~ @filter
    end
  end

  class StringFilter < RSpecTracer::Filter
    def match?(source_file)
      source_file[:file_name].include?(@filter)
    end
  end
end
