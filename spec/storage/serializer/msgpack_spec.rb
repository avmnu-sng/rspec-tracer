# frozen_string_literal: true

require 'rspec_tracer/storage/serializer/msgpack'

# Unit-level round-trip + type-extension contract for the Msgpack
# serializer. JsonBackend-level coverage at
# spec/storage/json_backend_msgpack_spec.rb exercises the full
# Snapshot pipeline; this spec pins the serializer's own behavior
# so a future refactor that drops the Time / Symbol extensions
# fails here loudly rather than only at the
# "NoMethodError: undefined method 'to_msgpack' for an instance of
# Time" / "Symbol -> String coercion" symptom level.
# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer::Storage::Serializer::Msgpack do
  describe 'round-trip' do
    it 'preserves String values' do
      bytes = described_class.encode('id_1' => 'value')

      expect(described_class.decode(bytes)).to eq('id_1' => 'value')
    end

    it 'preserves Integer values' do
      bytes = described_class.encode('count' => 42)

      expect(described_class.decode(bytes)).to eq('count' => 42)
    end

    it 'preserves nested Hash + Array structure' do
      payload = { 'deps' => { 'ex_1' => ['/a.rb', '/b.rb'] } }
      bytes = described_class.encode(payload)

      expect(described_class.decode(bytes)).to eq(payload)
    end

    it 'preserves Time values losslessly (the bug at the heart of #182)' do
      time = Time.utc(2026, 5, 13, 12, 34, 56, 789_012)
      bytes = described_class.encode('started_at' => time)
      result = described_class.decode(bytes)

      expect(result['started_at']).to eq(time)
    end

    it 'preserves Time nanosecond precision' do
      time = Time.at(1_715_000_000, 123_456_789, :nanosecond).utc
      bytes = described_class.encode('ts' => time)
      result = described_class.decode(bytes)

      aggregate_failures do
        expect(result['ts']).to eq(time)
        expect(result['ts'].tv_nsec).to eq(123_456_789)
      end
    end

    it 'canonicalizes Time round-trip to UTC (timezone-independent on-disk bytes)' do
      local = Time.utc(2026, 5, 13, 12, 0, 0).getlocal('+05:00')
      bytes = described_class.encode('ts' => local)
      result = described_class.decode(bytes)

      aggregate_failures do
        expect(result['ts']).to be_utc
        expect(result['ts']).to eq(local)
      end
    end

    it 'preserves Symbol values (msgpack default coerces to String)' do
      bytes = described_class.encode('status' => :passed)
      result = described_class.decode(bytes)

      aggregate_failures do
        expect(result['status']).to eq(:passed)
        expect(result['status']).to be_a(Symbol)
      end
    end

    it 'preserves Symbol inside nested Hash + Array' do
      payload = { 'examples' => { 'ex_1' => { 'status' => :flaky, 'tags' => %i[slow integration] } } }
      bytes = described_class.encode(payload)
      result = described_class.decode(bytes)

      aggregate_failures do
        expect(result['examples']['ex_1']['status']).to eq(:flaky)
        expect(result['examples']['ex_1']['tags']).to eq(%i[slow integration])
      end
    end

    it 'preserves a representative cache payload mixing Time + Symbol values' do
      payload = representative_cache_payload
      bytes = described_class.encode(payload)

      expect(described_class.decode(bytes)).to eq(payload)
    end
  end

  describe 'on-disk encoding' do
    it 'emits zlib-deflated msgpack bytes (caller inflates + decodes)' do
      bytes = described_class.encode('any' => 'payload')

      expect { Zlib::Inflate.inflate(bytes) }.not_to raise_error
    end

    it 'reports the .msgpack.gz extension for JsonBackend layout' do
      expect(described_class.extension).to eq('msgpack.gz')
    end
  end

  describe '.available?' do
    it 'is true when the msgpack gem loads cleanly' do
      expect(described_class.available?).to be(true)
    end
  end

  # Helper kept out of the example body so RSpec/ExampleLength does
  # not flag the realistic-shape regression test. Mirrors a
  # last_run-style payload with Time started_at + Symbol status.
  def representative_cache_payload
    {
      'run_id' => 'abc123',
      'recorded_at' => Time.utc(2026, 5, 13, 0, 0, 0),
      'examples' => {
        'ex_1' => {
          'status' => :passed,
          'execution_result' => {
            'started_at' => Time.utc(2026, 5, 13, 12, 0, 0),
            'run_time' => 0.012
          }
        }
      }
    }
  end
end
# rubocop:enable RSpec/ExampleLength
