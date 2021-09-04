# frozen_string_literal: true

module RSpecTracer
  class MessagePackSerializer < Serializer
    ENCODING = Encoding::BINARY
    EXTENSION = 'msgpack'

    class << self
      def serialize(object)
        MessagePack.pack(object)
      end

      def deserialize(input)
        MessagePack.unpack(input)
      end
    end
  end
end
