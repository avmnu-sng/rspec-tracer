# frozen_string_literal: true

require 'securerandom'
require_relative '../app/student'

RSpec.describe Student do
  let(:registration_id) { SecureRandom.uuid }

  subject { Student.new(registration_id) }

  describe '#name=' do
    context 'without name' do
      it 'does not set name' do
        expect { subject.name = nil }.not_to change(subject, :details)
      end
    end

    context 'with name' do
      it 'sets name' do
        expect { subject.name = 'avmnu-sng' }
          .to change(subject, :details).from({}).to({ name: 'avmnu-sng' })
      end
    end
  end

  describe '#email=' do
    xcontext 'without email' do
      it 'does not set email' do
        expect { subject.email = nil }.not_to change(subject, :details)
      end
    end

    context 'with email' do
      it 'sets email' do
        expect { subject.email = 'abhisinghabhimanyu@gmail.com' }
          .to change(subject, :details).from({}).to({ email: 'abhisinghabhimanyu@gmail.com' })
      end
    end
  end

  describe '#mobile=' do
    if ENV.fetch('FORCE_FAIL', 'false') == 'true'
      before { expect(true).to eq(false) }
    end

    context 'without mobile' do
      it 'does not set mobile' do
        expect { subject.mobile = nil }.not_to change(subject, :details)
      end
    end

    context 'with mobile' do
      it 'sets mobile' do
        expect { subject.mobile = '0123456789' }
          .to change(subject, :details).from({}).to({ mobile: '0123456789' })
      end
    end
  end

  describe '#enroll' do
    context 'without course' do
      it 'does not enroll' do
        expect { subject.enroll(nil) }.not_to change(subject, :enrolled_in)
      end
    end

    context 'with course' do
      let(:course) { Course.new(:rspec_tracer, 'RSpec Tracer') }

      it 'enroll student' do
        expect { subject.enroll(course) }
          .to change(subject, :enrolled_in).from(Set.new).to(Set.new([course]))
          .and change(course, :enrolled_students).from(Set.new).to(Set.new([subject]))
      end
    end
  end
end
