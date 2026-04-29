# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Comments', type: :request do
  let(:post_record) { create(:post) }

  describe 'GET /posts/:post_id/comments' do
    it 'returns 200' do
      get post_comments_path(post_record)
      expect(response).to have_http_status(:ok)
    end

    it 'renders the post title' do
      get post_comments_path(post_record)
      expect(response.body).to include(post_record.title)
    end

    it 'lists existing comments' do
      create(:comment, post: post_record, body: 'Unique comment body.')
      get post_comments_path(post_record)
      expect(response.body).to include('Unique comment body')
    end

    it 'shows empty state when no comments' do
      get post_comments_path(post_record)
      expect(response.body).to include('No comments yet')
    end

    it 'returns 404 for missing post' do
      get post_comments_path('no-such-post')
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /posts/:post_id/comments' do
    let(:user) { create(:user) }

    context 'with valid params' do
      let(:params) { { comment: { body: 'Nice post', user_id: user.id } } }

      it 'creates a comment' do
        expect { post post_comments_path(post_record), params: params }
          .to change(Comment, :count).by(1)
      end

      it 'redirects to the post' do
        post post_comments_path(post_record), params: params
        expect(response).to redirect_to(post_path(post_record))
      end

      it 'enqueues the notify_author mailer' do
        expect do
          post post_comments_path(post_record), params: params
        end.to have_enqueued_mail(PostMailer, :notify_author)
      end
    end

    context 'with invalid params' do
      let(:params) { { comment: { body: '', user_id: user.id } } }

      it 'does not create a comment' do
        expect { post post_comments_path(post_record), params: params }
          .not_to change(Comment, :count)
      end

      it 'redirects with alert flash' do
        post post_comments_path(post_record), params: params
        follow_redirect!
        expect(flash[:alert]).to include("Body can't be blank")
      end
    end
  end

  describe 'DELETE /posts/:post_id/comments/:id' do
    let!(:comment) { create(:comment, post: post_record) }

    it 'destroys the comment' do
      expect { delete post_comment_path(post_record, comment) }
        .to change(Comment, :count).by(-1)
    end

    it 'redirects to the post' do
      delete post_comment_path(post_record, comment)
      expect(response).to redirect_to(post_path(post_record))
    end
  end
end
