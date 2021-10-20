# frozen_string_literal: true

require_relative '../app/course'
require_relative '../app/student'

RSpec.describe Course do
  subject { Course.new(:rspec_tracer, 'RSpec Tracer') }

  describe 'enrolled' do
    context 'without student' do
      it 'does not enroll' do
        expect { subject.enrolled(nil) }.not_to change(subject, :students)
      end
    end

    context 'with student' do
      let(:student) do
        student = Student.new('avmnu-sng')
        student.name = 'Abhimanyu Singh'
        student.email = 'abhisinghabhimanyu@gmail.com'

        student
      end

      it 'enrolls student' do
        expect { subject.enrolled(student) }
          .to change(subject, :enrolled_students).from(Set.new).to(Set.new([student]))
      end
    end
  end
end
