# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostMailer, type: :mailer do
  describe '#notify_author' do
    let(:author) { create(:user, email: 'author@example.com', name: 'Author User') }
    let(:commenter) { create(:user, name: 'Commenter User') }
    let(:post_record) { create(:post, user: author, title: 'The Post') }
    let(:comment) { create(:comment, user: commenter, post: post_record, body: 'Nice post!') }
    let(:mail) { described_class.notify_author(post_record, comment) }

    it 'is sent to the post author' do
      expect(mail.to).to eq([ author.email ])
    end

    it 'is sent from the configured default' do
      expect(mail.from).to eq([ 'notifications@example.com' ])
    end

    it 'has a subject mentioning the post title' do
      expect(mail.subject).to eq('New comment on "The Post"')
    end

    it 'renders an HTML part' do
      html = mail.html_part.body.to_s
      expect(html).to include('New comment')
      expect(html).to include('Commenter User')
      expect(html).to include('Nice post!')
    end

    it 'renders a text part' do
      text = mail.text_part.body.to_s
      expect(text).to include('Commenter User')
      expect(text).to include('Nice post!')
    end

    it 'includes a link to the post in HTML' do
      html = mail.html_part.body.to_s
      expect(html).to include('View post')
    end
  end

  describe '#weekly_digest' do
    let(:user) { create(:user, email: 'digest@example.com', name: 'Digest User') }
    let(:mail) { described_class.weekly_digest(user) }

    it 'is sent to the user' do
      expect(mail.to).to eq([ user.email ])
    end

    it 'has the weekly digest subject' do
      expect(mail.subject).to eq('Your weekly digest')
    end

    context 'when user has published posts' do
      before do
        create(:post, :published, user: user, title: 'Recent Post')
      end

      it 'lists the recent posts' do
        expect(mail.html_part.body.to_s).to include('Recent Post')
      end
    end

    context 'when user has no published posts' do
      it 'shows the empty state' do
        expect(mail.html_part.body.to_s).to include('no recently published posts')
      end
    end
  end
end
