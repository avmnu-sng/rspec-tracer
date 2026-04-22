# frozen_string_literal: true

class Discount
  def initialize(percentage)
    raise ArgumentError, 'percentage must be between 0 and 100' unless (0..100).cover?(percentage)

    @percentage = percentage
  end

  def apply(price)
    price - (price * @percentage / 100.0)
  end

  def describe
    "#{@percentage}% off"
  end
end
