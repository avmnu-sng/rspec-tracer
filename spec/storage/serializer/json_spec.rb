# frozen_string_literal: true

require 'json'
require 'rspec_tracer/storage/serializer/json'

# Direct unit-level spec for the Json serializer. Lives in this
# subdirectory so mutant-rspec's Selector::Expression attributes
# these tests to the Storage::Serializer::Json subject at its own
# level (not via Storage::* fallthrough, which would otherwise be
# shadowed once Storage::Serializer::Msgpack got a direct
# describe of its own in msgpack_spec.rb).
# rubocop:disable RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Storage::Serializer::Json do
  describe '.extension' do
    it 'returns the literal string "json" (drives the on-disk file shape)' do
      expect(described_class.extension).to eq('json')
    end

    it 'is a String, not a Symbol or nil' do
      expect(described_class.extension).to be_a(String)
    end
  end

  describe '.encode' do
    it 'returns a String' do
      expect(described_class.encode('a' => 1)).to be_a(String)
    end

    it 'returns valid JSON parseable back to the input Hash' do
      payload = { 'a' => 1, 'b' => [2, 3, 'four'], 'c' => { 'nested' => true } }

      encoded = described_class.encode(payload)

      expect(JSON.parse(encoded)).to eq(payload)
    end

    it 'produces pretty-printed JSON with newlines + indentation (mutant kills `JSON.generate` swap)' do
      encoded = described_class.encode('a' => 1, 'b' => 2)

      expect(encoded).to include("\n")
      expect(encoded).to match(/^\s+"[ab]"/m)
    end

    it 'produces output that round-trips through .decode losslessly' do
      payload = { 'roundtrip' => 'value', 'count' => 42 }

      decoded = described_class.decode(described_class.encode(payload))

      expect(decoded).to eq(payload)
    end

    it 'encodes nil values' do
      expect(JSON.parse(described_class.encode('key' => nil))).to eq('key' => nil)
    end

    it 'encodes Array values' do
      expect(JSON.parse(described_class.encode('list' => [1, 2, 3]))).to eq('list' => [1, 2, 3])
    end

    it 'encodes empty Hash' do
      expect(described_class.encode({})).to eq('{}')
    end
  end

  describe '.decode' do
    it 'parses a JSON string into the corresponding Ruby Hash' do
      expect(described_class.decode('{"a":1,"b":"two"}')).to eq('a' => 1, 'b' => 'two')
    end

    it 'parses an Array-rooted JSON document' do
      expect(described_class.decode('[1,2,3]')).to eq([1, 2, 3])
    end

    it 'returns String values as UTF-8 (mutant kills `force_encoding` arg swap)' do
      result = described_class.decode('{"k":"value"}')

      expect(result['k'].encoding).to eq(Encoding::UTF_8)
    end

    it 'handles binary-encoded input by force-encoding to UTF-8 (mutant kills `force_encoding` drop)' do
      bytes = String.new('{"k":"value"}', encoding: Encoding::ASCII_8BIT)

      expect(described_class.decode(bytes)).to eq('k' => 'value')
    end

    it 'preserves the input bytes string encoding (mutant kills `.dup` drop)' do
      bytes = String.new('{"k":"value"}', encoding: Encoding::ASCII_8BIT)

      described_class.decode(bytes)

      expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'parses non-ASCII characters correctly (the user-issue-fix that the UTF-8 force protects)' do
      json = '{"name":"café"}'

      result = described_class.decode(json)

      expect(result['name']).to eq('café')
    end

    it 'raises JSON::ParserError on malformed input' do
      expect { described_class.decode('{not json}') }.to raise_error(JSON::ParserError)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations
