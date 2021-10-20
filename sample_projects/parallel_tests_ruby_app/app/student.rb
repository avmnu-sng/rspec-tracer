# frozen_string_literal: true

require 'set'

class Student
  attr_reader :registration_id, :details

  def initialize(registration_id)
    @registration_id = registration_id
    @details = {}
    @courses = Set.new
  end

  def name=(name)
    @details[:name] = name if name
  end

  def email=(email)
    @details[:email] = email if email
  end

  def mobile=(mobile)
    @details[:mobile] = mobile if mobile
  end

  def enroll(course)
    return if course.nil?

    @courses << course
    course.enrolled(self)
  end

  def enrolled_in
    @courses
  end
end
