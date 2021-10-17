# frozen_string_literal: true

RSpec.describe 'Dummy 12' do
  1.upto(12) do |num|
    context "with num=#{num}" do
      it 'validates twice of the num' do
        expect(num + num).to eq(2 * num)
      end
    end
  end
end
