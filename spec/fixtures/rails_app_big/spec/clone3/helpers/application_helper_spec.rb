# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper, type: :helper do
  describe '#page_title' do
    it 'returns the base when no parts given' do
      expect(helper.page_title).to eq('Rails App')
    end

    it 'joins parts with the separator' do
      expect(helper.page_title('Posts', 'Latest')).to eq('Posts · Latest · Rails App')
    end

    it 'compact-blanks nil / empty entries' do
      expect(helper.page_title(nil, '', 'Posts')).to eq('Posts · Rails App')
    end
  end

  describe '#flash_class' do
    it 'returns the info class for notices' do
      expect(helper.flash_class('notice')).to eq('flash flash-info')
    end

    it 'returns the warning class for alerts' do
      expect(helper.flash_class('alert')).to eq('flash flash-warning')
    end

    it 'returns the base class for unknown kinds' do
      expect(helper.flash_class('something-else')).to eq('flash')
    end

    it 'accepts symbols' do
      expect(helper.flash_class(:notice)).to eq('flash flash-info')
    end
  end
end
