# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe RSpecTracer::Logger do
  let(:out) { StringIO.new }

  # Drive every level method once so each spec pins the full gate
  # table for its log level.
  def emit_all(logger)
    logger.debug('d')
    logger.info('i')
    logger.warn('w')
    logger.error('e')
  end

  describe 'level gating' do
    it 'emits all four levels at debug (1)' do
      emit_all(described_class.new(1, out: out))
      expect(out.string).to eq("d\ni\nw\ne\n")
    end

    it 'suppresses debug at info (2)' do
      emit_all(described_class.new(2, out: out))
      expect(out.string).to eq("i\nw\ne\n")
    end

    it 'emits only warn and error at warn (3)' do
      emit_all(described_class.new(3, out: out))
      expect(out.string).to eq("w\ne\n")
    end

    it 'emits only error at error (4)' do
      emit_all(described_class.new(4, out: out))
      expect(out.string).to eq("e\n")
    end

    it 'suppresses everything at off (0)' do
      emit_all(described_class.new(0, out: out))
      expect(out.string).to be_empty
    end
  end

  describe 'destination resolution' do
    around do |example|
      # Every path below exercises the fallback chain; pin the
      # class-level default to a known state and restore after.
      previous = described_class.default_out
      example.run
    ensure
      described_class.default_out = previous
    end

    it 'binds to $stdout when out: is omitted and no default_out is set' do
      described_class.default_out = nil
      expect { emit_all(described_class.new(1)) }.to output("d\ni\nw\ne\n").to_stdout
    end

    it 'binds to the class-level default_out when set and out: is omitted' do
      default = StringIO.new
      described_class.default_out = default
      emit_all(described_class.new(1))
      expect(default.string).to eq("d\ni\nw\ne\n")
    end

    it 'prefers an explicit out: over the class-level default_out' do
      described_class.default_out = StringIO.new
      emit_all(described_class.new(1, out: out))
      expect(out.string).to eq("d\ni\nw\ne\n")
    end

    it 'writes nothing through the class-level default_out when out: is explicit' do
      default = StringIO.new
      described_class.default_out = default
      emit_all(described_class.new(1, out: out))
      expect(default.string).to be_empty
    end

    it 'captures the destination at construction, not per write' do
      described_class.default_out = out
      logger = described_class.new(1)
      described_class.default_out = StringIO.new
      logger.error('after rebind')
      expect(out.string).to eq("after rebind\n")
    end
  end
end
