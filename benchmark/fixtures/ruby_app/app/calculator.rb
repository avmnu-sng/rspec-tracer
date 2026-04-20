# frozen_string_literal: true

class Calculator
  def add(a, b) = a + b
  def subtract(a, b) = a - b
  def multiply(a, b) = a * b

  def divide(a, b)
    raise ZeroDivisionError if b.zero?

    a.to_f / b
  end

  def modulo(a, b)
    raise ZeroDivisionError if b.zero?

    a % b
  end
end
