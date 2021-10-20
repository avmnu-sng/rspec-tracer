# frozen_string_literal: true

RSpec.describe 'Dummy 11' do
  1.upto(11) do |num|
    context "with num=#{num}" do
      it 'validates twice of the num' do
        expect(num + num).to eq(2 * num)
      end
    end
  end
end
