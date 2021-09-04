# frozen_string_literal: true

module RSpecTracer
  class JSONSerializer < Serializer
    ENCODING = Encoding::UTF_8
    EXTENSION = 'json'

    class << self
      def serialize(object)
        JSON.generate(object)
      end

      def deserialize(input)
        JSON.parse(input)
      end
    end
  end
end
