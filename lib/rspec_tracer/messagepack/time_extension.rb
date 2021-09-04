# frozen_string_literal: true

require 'msgpack'

MessagePack::DefaultFactory.register_type(
  MessagePack::Timestamp::TYPE,
  Time,
  packer: MessagePack::Time::Packer,
  unpacker: MessagePack::Time::Unpacker
)
