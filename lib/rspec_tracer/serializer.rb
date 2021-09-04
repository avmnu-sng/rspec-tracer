# frozen_string_literal: true

module RSpecTracer
  class Serializer
    ENCODING = nil
    EXTENSION = nil

    class << self
      def serialize(_object)
        raise NotImplementedError, 'You must implement serialize.'
      end

      def deserialize(_input)
        raise NotImplementedError, 'You must implement deserialize.'
      end
    end
  end
end

require_relative 'serializers/json_serializer'
require_relative 'serializers/message_pack_serializer'
