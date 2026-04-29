# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommentsChannel, type: :channel do
  let(:post_record) { create(:post) }

  before do
    stub_connection
  end

  describe '#subscribed' do
    context 'when post exists' do
      it 'subscribes successfully' do
        subscribe(post_slug: post_record.slug)
        expect(subscription).to be_confirmed
      end

      it 'streams from the post-specific channel' do
        subscribe(post_slug: post_record.slug)
        expect(subscription).to have_stream_from("comments:#{post_record.id}")
      end
    end

    context 'when post does not exist' do
      it 'rejects the subscription' do
        subscribe(post_slug: 'no-such-post')
        expect(subscription).to be_rejected
      end
    end
  end

  describe '#unsubscribed' do
    it 'stops all streams' do
      subscribe(post_slug: post_record.slug)
      expect { unsubscribe }.not_to raise_error
    end
  end

  describe 'broadcast integration' do
    it 'relays Comment after_create_commit broadcasts' do
      subscribe(post_slug: post_record.slug)
      expect do
        create(:comment, post: post_record, body: 'Live comment')
      end.to have_broadcasted_to("comments:#{post_record.id}")
        .with(a_hash_including(body: kind_of(String)))
    end
  end
end
