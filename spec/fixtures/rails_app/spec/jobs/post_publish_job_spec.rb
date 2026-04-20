# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostPublishJob, type: :job do
  describe '#perform' do
    context 'when post is draft' do
      let(:post) { create(:post, :draft) }

      it 'publishes the post' do
        expect { described_class.new.perform(post.id) }.to change { post.reload.published? }.from(false).to(true)
      end

      it 'sets published_at close to now' do
        described_class.new.perform(post.id)
        expect(post.reload.published_at).to be_within(5.seconds).of(Time.current)
      end
    end

    context 'when post is already published' do
      let(:post) { create(:post, :published) }

      it 'is a no-op' do
        before_time = post.published_at
        described_class.new.perform(post.id)
        expect(post.reload.published_at).to be_within(1.second).of(before_time)
      end
    end

    context 'when post does not exist' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect { described_class.new.perform(999_999) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    it 'queues on :default' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe 'enqueue behaviour' do
    it 'enqueues on perform_later' do
      post = create(:post, :draft)
      expect { described_class.perform_later(post.id) }
        .to have_enqueued_job(described_class).with(post.id)
    end
  end
end
