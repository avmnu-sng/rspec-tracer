# frozen_string_literal: true

RSpec.describe 'Dummy 6' do
  1.upto(6) do |num|
    context "with num=#{num}" do
      it 'validates twice of the num' do
        expect(num + num).to eq(2 * num)
      end
    end
  end
end
