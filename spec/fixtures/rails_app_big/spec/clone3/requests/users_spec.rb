# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Users', type: :request do
  describe 'GET /users' do
    it 'returns 200' do
      get users_path
      expect(response).to have_http_status(:ok)
    end

    it 'renders the index template' do
      get users_path
      expect(response.body).to include('All Users')
    end

    it 'lists existing users' do
      user = create(:user, name: 'Alice')
      get users_path
      expect(response.body).to include('Alice')
    end

    it 'shows empty state when no users' do
      get users_path
      expect(response.body).to include('No users yet.')
    end
  end

  describe 'GET /users/:id' do
    let(:user) { create(:user, :activated) }

    it 'returns 200' do
      get user_path(user)
      expect(response).to have_http_status(:ok)
    end

    it 'renders the user' do
      get user_path(user)
      expect(response.body).to include(user.display_name)
    end

    it 'lists the user\'s posts' do
      post = create(:post, user: user, title: 'Post Alpha')
      get user_path(user)
      expect(response.body).to include('Post Alpha')
    end

    it 'returns 404 for missing user' do
      get user_path('999999')
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /users/new' do
    it 'returns 200' do
      get new_user_path
      expect(response).to have_http_status(:ok)
    end

    it 'renders the form' do
      get new_user_path
      expect(response.body).to include('New User')
    end
  end

  describe 'POST /users' do
    context 'with valid params' do
      let(:params) { { user: { name: 'Alice', email: 'alice@example.com', role: 'member' } } }

      it 'creates a user' do
        expect { post users_path, params: params }.to change(User, :count).by(1)
      end

      it 'redirects to the user' do
        post users_path, params: params
        expect(response).to redirect_to(User.last)
      end

      it 'sets a notice flash' do
        post users_path, params: params
        follow_redirect!
        expect(flash[:notice]).to eq('User was successfully created.')
      end
    end

    context 'with invalid params' do
      let(:params) { { user: { name: '', email: 'not-an-email', role: 'member' } } }

      it 'does not create a user' do
        expect { post users_path, params: params }.not_to change(User, :count)
      end

      it 'returns 422' do
        post users_path, params: params
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'renders error messages' do
        post users_path, params: params
        expect(response.body).to include('prevented this user from saving')
      end
    end
  end

  describe 'GET /users/:id/edit' do
    let(:user) { create(:user) }

    it 'returns 200' do
      get edit_user_path(user)
      expect(response).to have_http_status(:ok)
    end

    it 'renders the form' do
      get edit_user_path(user)
      expect(response.body).to include('Edit')
    end
  end

  describe 'PATCH /users/:id' do
    let(:user) { create(:user, name: 'Old Name') }

    context 'with valid params' do
      it 'updates the user' do
        patch user_path(user), params: { user: { name: 'New Name' } }
        expect(user.reload.name).to eq('New Name')
      end

      it 'redirects to the user (using the post-update to_param)' do
        patch user_path(user), params: { user: { name: 'New Name' } }
        expect(response).to redirect_to(user_path(user.reload))
      end
    end

    context 'with invalid params' do
      it 'returns 422' do
        patch user_path(user), params: { user: { email: 'invalid' } }
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'does not update the user' do
        patch user_path(user), params: { user: { email: 'invalid' } }
        expect(user.reload.email).not_to eq('invalid')
      end
    end
  end

  describe 'DELETE /users/:id' do
    let!(:user) { create(:user) }

    it 'destroys the user' do
      expect { delete user_path(user) }.to change(User, :count).by(-1)
    end

    it 'redirects to the index' do
      delete user_path(user)
      expect(response).to redirect_to(users_path)
    end

    it 'returns 303 (see_other)' do
      delete user_path(user)
      expect(response).to have_http_status(:see_other)
    end

    it 'destroys dependent posts and comments' do
      post_record = create(:post, user: user)
      comment = create(:comment, user: user, post: post_record)
      delete user_path(user)
      expect(Post.exists?(post_record.id)).to be(false)
      expect(Comment.exists?(comment.id)).to be(false)
    end
  end
end
