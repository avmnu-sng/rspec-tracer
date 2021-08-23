# frozen_string_literal: true

require 'set'

class Course
  attr_reader :id, :name

  def initialize(id, name)
    @id = id
    @name = name
    @students = Set.new
  end

  def enrolled(student)
    return unless student

    @students << student
  end

  def enrolled_students
    @students
  end

  def enrolled_students_id
    @students.map(&:registration_id)
  end
end
