# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UsersHelper, type: :helper do
  describe '#user_avatar_url' do
    it 'returns a gravatar URL' do
      user = build(:user, email: 'alice@example.com')
      expect(helper.user_avatar_url(user)).to include('gravatar.com/avatar/')
    end

    it 'uses an md5 of the lowercased email' do
      user = build(:user, email: 'Alice@Example.com')
      expected_digest = Digest::MD5.hexdigest('alice@example.com')
      expect(helper.user_avatar_url(user)).to include(expected_digest)
    end

    it 'defaults size to 64' do
      user = build(:user, email: 'a@b.co')
      expect(helper.user_avatar_url(user)).to include('s=64')
    end

    it 'respects custom size' do
      user = build(:user, email: 'a@b.co')
      expect(helper.user_avatar_url(user, size: 128)).to include('s=128')
    end

    it 'includes identicon default' do
      user = build(:user, email: 'a@b.co')
      expect(helper.user_avatar_url(user)).to include('d=identicon')
    end

    it 'returns nil for blank user' do
      expect(helper.user_avatar_url(nil)).to be_nil
    end
  end

  describe '#role_badge' do
    it 'wraps the role in a span with role class' do
      user = build(:user, :admin)
      result = helper.role_badge(user)
      expect(result).to include('role-admin')
      expect(result).to include('Admin')
    end

    it 'uses translated role text' do
      user = build(:user, role: 'guest')
      expect(helper.role_badge(user)).to include('Guest')
    end

    it 'returns HTML-safe output' do
      expect(helper.role_badge(build(:user))).to be_html_safe
    end
  end

  describe '#activation_status' do
    it 'returns the activated_at label when activated' do
      user = build(:user, :activated, activated_at: Time.zone.local(2026, 4, 20, 10))
      expect(helper.activation_status(user)).to include('Activated')
      expect(helper.activation_status(user)).to match(/Apr|20/)
    end

    it 'returns the pending label when not activated' do
      user = build(:user)
      expect(helper.activation_status(user)).to eq('Awaiting activation')
    end
  end
end
