# frozen_string_literal: true

RSpec.describe RSpecTracer::TimeFormatter do
  describe '#format_time' do
    {
      0.03456794 => '0.03457 seconds',
      0.005 => '0.005 seconds',
      1 => '1 second',
      3 => '3 seconds',
      60 => '1 minute',
      63.45 => '1 minute 3.45 seconds',
      168 => '2 minutes 48 seconds',
      180 => '3 minutes',
      3600.0 => '1 hour'
    }.freeze.each_pair do |seconds, formatted_time|
      it "formats #{seconds} seconds into #{formatted_time}" do
        expect(described_class.format_time(seconds)).to eq(formatted_time)
      end
    end
  end
end
