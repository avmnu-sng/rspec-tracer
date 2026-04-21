# frozen_string_literal: true

RSpec.describe RSpecTracer::TimeFormatter do
  describe '.format_time' do
    {
      # sub-second precision
      0.005 => '0.005 seconds',
      0.03456794 => '0.03457 seconds',
      # zero + singular + plural under a minute
      0 => '0 seconds',
      1 => '1 second',
      3 => '3 seconds',
      59 => '59 seconds',
      # exact minute boundary + minute-plurality
      60 => '1 minute',
      120 => '2 minutes',
      180 => '3 minutes',
      # minute + fractional second, minute + integer second
      63.45 => '1 minute 3.45 seconds',
      168 => '2 minutes 48 seconds',
      # exact hour + hour-plurality
      3600.0 => '1 hour',
      7200 => '2 hours',
      # hour with zero-remainder minute branch
      3601 => '1 hour 1 second',
      # hour + minute, hour + minute + second
      3660 => '1 hour 1 minute',
      3661 => '1 hour 1 minute 1 second',
      # day boundary + multi-day + day-with-sub-units
      86_400 => '1 day',
      86_401 => '1 day 1 second',
      172_800 => '2 days',
      90_061 => '1 day 1 hour 1 minute 1 second'
    }.each_pair do |seconds, expected|
      it "formats #{seconds} seconds into #{expected.inspect}" do
        expect(described_class.format_time(seconds)).to eq(expected)
      end
    end

    it 'returns "0 seconds" for a negative input (degenerate but defined)' do
      expect(described_class.format_time(-5)).to eq('0 seconds')
    end
  end
end
