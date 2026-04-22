# frozen_string_literal: true

class Inventory
  def initialize
    @items = Hash.new(0)
  end

  def add(item, qty = 1)
    @items[item] += qty
  end

  def remove(item, qty = 1)
    return false if @items[item] < qty

    @items[item] -= qty
    true
  end

  def count(item) = @items[item]
  def total = @items.values.sum
  def empty? = total.zero?
end
