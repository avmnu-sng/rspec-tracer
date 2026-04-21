# frozen_string_literal: true

require 'rspec_tracer/time_formatter'
require 'rantly/rspec_extensions'

# Grammar the formatter is supposed to produce:
#   "<number> <unit>[s]" tokens separated by single spaces,
#   unit ∈ { second, minute, hour, day }, optional 's' plural.
# Hoisted to file scope so rubocop-rspec's LeakyConstantDeclaration +
# Lint/ConstantDefinitionInBlock stay quiet.
TIME_FORMAT_TOKEN = /\d+(?:\.\d+)?\s+(?:second|minute|hour|day)s?/
TIME_FORMAT_RE    = /\A#{TIME_FORMAT_TOKEN}(?:\s+#{TIME_FORMAT_TOKEN})*\z/

RSpec.describe RSpecTracer::TimeFormatter do
  describe '.format_time' do
    it 'returns a non-empty string for any non-negative integer second count' do
      property_of { range(0, 86_399) }.check(100) do |secs|
        expect(described_class.format_time(secs)).to be_a(String).and(satisfy { |s| !s.empty? })
      end
    end

    it 'conforms to the "<number> <unit>[s]" grammar' do
      property_of { range(0, 86_399) }.check(100) do |secs|
        expect(described_class.format_time(secs)).to match(TIME_FORMAT_RE)
      end
    end

    it 'handles sub-second fractional input' do
      property_of { range(1, 999_999).to_f / 1_000_000 }.check(100) do |frac|
        expect(described_class.format_time(frac)).to match(TIME_FORMAT_RE)
      end
    end
  end
end
