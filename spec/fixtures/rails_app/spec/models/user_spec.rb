# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, type: :model do
  describe 'validations' do
    subject(:user) { build(:user) }

    it { is_expected.to be_valid }

    context 'with name' do
      it 'is required' do
        user.name = nil
        expect(user).not_to be_valid
        expect(user.errors[:name]).to include("can't be blank")
      end

      it 'rejects length < 2' do
        user.name = 'A'
        expect(user).not_to be_valid
      end

      it 'rejects length > 100' do
        user.name = 'A' * 101
        expect(user).not_to be_valid
      end

      it 'accepts length 2' do
        user.name = 'Ab'
        expect(user).to be_valid
      end

      it 'accepts length 100' do
        user.name = 'A' * 100
        expect(user).to be_valid
      end
    end

    context 'with email' do
      it 'is required' do
        user.email = nil
        expect(user).not_to be_valid
        expect(user.errors[:email]).to include("can't be blank")
      end

      it 'is unique (case-insensitive)' do
        create(:user, email: 'DUPE@example.com')
        user.email = 'dupe@example.com'
        expect(user).not_to be_valid
        expect(user.errors[:email]).to include('has already been taken')
      end

      it 'rejects malformed addresses' do
        user.email = 'not-an-email'
        expect(user).not_to be_valid
      end

      it 'rejects missing @' do
        user.email = 'missingat.example.com'
        expect(user).not_to be_valid
      end

      it 'accepts plus-addressing' do
        user.email = 'user+tag@example.com'
        expect(user).to be_valid
      end

      it 'accepts subdomain addresses' do
        user.email = 'user@mail.example.co.uk'
        expect(user).to be_valid
      end
    end

    context 'with role' do
      it 'is required' do
        user.role = nil
        expect(user).not_to be_valid
      end

      it 'accepts admin' do
        user.role = 'admin'
        expect(user).to be_valid
      end

      it 'accepts member' do
        user.role = 'member'
        expect(user).to be_valid
      end

      it 'accepts guest' do
        user.role = 'guest'
        expect(user).to be_valid
      end

      it 'rejects unknown role' do
        user.role = 'superuser'
        expect(user).not_to be_valid
        expect(user.errors[:role]).to include('is not included in the list')
      end
    end
  end

  describe 'callbacks' do
    describe '#normalize_email' do
      it 'strips whitespace before validation' do
        user = build(:user, email: '  spaced@example.com  ')
        user.valid?
        expect(user.email).to eq('spaced@example.com')
      end

      it 'downcases before validation' do
        user = build(:user, email: 'MixedCase@Example.COM')
        user.valid?
        expect(user.email).to eq('mixedcase@example.com')
      end

      it 'does not touch nil email' do
        user = build(:user, email: nil)
        expect { user.valid? }.not_to raise_error
      end
    end
  end

  describe 'associations' do
    let(:user) { create(:user) }

    describe 'posts' do
      it 'has many posts' do
        post1 = create(:post, user: user)
        post2 = create(:post, user: user)
        expect(user.posts).to contain_exactly(post1, post2)
      end

      it 'destroys posts when user destroyed' do
        create_list(:post, 2, user: user)
        expect { user.destroy }.to change(Post, :count).by(-2)
      end
    end

    describe 'comments' do
      it 'has many comments' do
        post = create(:post)
        c1 = create(:comment, user: user, post: post)
        c2 = create(:comment, user: user, post: post)
        expect(user.comments).to contain_exactly(c1, c2)
      end

      it 'destroys comments when user destroyed' do
        post = create(:post)
        create_list(:comment, 2, user: user, post: post)
        expect { user.destroy }.to change(Comment, :count).by(-2)
      end
    end
  end

  describe 'scopes' do
    describe '.activated' do
      it 'returns only activated users' do
        activated = create(:user, :activated)
        create(:user) # not activated
        expect(described_class.activated).to contain_exactly(activated)
      end

      it 'returns empty relation when none activated' do
        create_list(:user, 3)
        expect(described_class.activated).to be_empty
      end
    end

    describe '.admins' do
      it 'returns only admin users' do
        admin = create(:user, :admin)
        create(:user, role: 'member')
        create(:user, role: 'guest')
        expect(described_class.admins).to contain_exactly(admin)
      end
    end

    describe '.recently_created' do
      it 'orders newest first' do
        older = create(:user, created_at: 2.days.ago)
        newer = create(:user, created_at: 1.day.ago)
        newest = create(:user, created_at: Time.current)
        expect(described_class.recently_created).to eq([ newest, newer, older ])
      end
    end
  end

  describe '#activate!' do
    context 'when not activated' do
      it 'sets activated_at' do
        user = create(:user)
        expect { user.activate! }.to change(user, :activated_at).from(nil)
      end

      it 'returns truthy' do
        user = create(:user)
        expect(user.activate!).to be_truthy
      end
    end

    context 'when already activated' do
      it 'returns false' do
        user = create(:user, :activated)
        expect(user.activate!).to be(false)
      end

      it 'does not change activated_at' do
        user = create(:user, :activated)
        expect { user.activate! }.not_to change(user, :activated_at)
      end
    end
  end

  describe '#activated?' do
    it 'is true when activated_at present' do
      expect(build(:user, :activated).activated?).to be(true)
    end

    it 'is false when activated_at nil' do
      expect(build(:user).activated?).to be(false)
    end
  end

  describe '#admin?' do
    it 'is true for admin role' do
      expect(build(:user, :admin).admin?).to be(true)
    end

    it 'is false for member role' do
      expect(build(:user, role: 'member').admin?).to be(false)
    end

    it 'is false for guest role' do
      expect(build(:user, role: 'guest').admin?).to be(false)
    end
  end

  describe '#display_name' do
    it 'returns name when present' do
      expect(build(:user, name: 'Alice', email: 'a@ex.com').display_name).to eq('Alice')
    end

    it 'falls back to email local part when name blank' do
      user = build(:user, email: 'alice@ex.com')
      user.name = ''
      expect(user.display_name).to eq('alice')
    end
  end

  describe '#to_param' do
    it 'includes id and parameterized name' do
      user = create(:user, name: 'Alice Wonderland')
      expect(user.to_param).to eq("#{user.id}-alice-wonderland")
    end

    it 'handles names with punctuation' do
      user = create(:user, name: "O'Reilly")
      expect(user.to_param).to end_with('-o-reilly')
    end
  end

  describe 'constant ROLES' do
    it 'contains the three known roles' do
      expect(described_class::ROLES).to eq(%w[admin member guest])
    end

    it 'is frozen' do
      expect(described_class::ROLES).to be_frozen
    end
  end
end
