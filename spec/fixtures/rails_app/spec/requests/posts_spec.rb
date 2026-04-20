# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Posts', type: :request do
  describe 'GET /posts' do
    it 'returns 200' do
      get posts_path
      expect(response).to have_http_status(:ok)
    end

    it 'lists published posts' do
      create(:post, :published, title: 'Published Post')
      get posts_path
      expect(response.body).to include('Published Post')
    end

    it 'omits draft posts by default' do
      create(:post, :draft, title: 'Secret Draft')
      get posts_path
      expect(response.body).not_to include('Secret Draft')
    end

    it 'shows drafts when drafts=1' do
      create(:post, :draft, title: 'Secret Draft')
      get posts_path, params: { drafts: '1' }
      expect(response.body).to include('Secret Draft')
    end

    it 'filters by user_id' do
      user = create(:user)
      create(:post, :published, user: user, title: 'By Alice')
      create(:post, :published, title: 'By Someone Else')
      get posts_path, params: { user_id: user.id }
      expect(response.body).to include('By Alice')
      expect(response.body).not_to include('By Someone Else')
    end

    it 'renders JSON when requested' do
      create(:post, :published)
      get posts_path(format: :json)
      expect(response.content_type).to start_with('application/json')
      body = JSON.parse(response.body)
      expect(body).to have_key('posts')
      expect(body).to have_key('meta')
    end

    it 'includes post count in JSON meta' do
      create_list(:post, 3, :published)
      get posts_path(format: :json)
      expect(JSON.parse(response.body).dig('meta', 'count')).to eq(3)
    end
  end

  describe 'GET /posts/:id' do
    let(:post_record) { create(:post, :published, title: 'My Post') }

    it 'returns 200' do
      get post_path(post_record)
      expect(response).to have_http_status(:ok)
    end

    it 'renders the title' do
      get post_path(post_record)
      expect(response.body).to include('My Post')
    end

    it 'renders the body rich text' do
      post_record.update!(body: '<p>My body content.</p>')
      get post_path(post_record)
      expect(response.body).to include('My body content.')
    end

    it 'renders categories' do
      category = create(:category, name: 'Ruby')
      post_record.categories << category
      get post_path(post_record)
      expect(response.body).to include('Ruby')
    end

    it 'renders JSON when requested' do
      get post_path(post_record, format: :json)
      expect(response.content_type).to start_with('application/json')
      body = JSON.parse(response.body)
      expect(body['title']).to eq('My Post')
      expect(body).to have_key('categories')
      expect(body).to have_key('comments_count')
    end

    it 'returns 404 for missing slug' do
      get post_path('does-not-exist')
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /posts/new' do
    it 'returns 200' do
      get new_post_path
      expect(response).to have_http_status(:ok)
    end

    it 'renders the form' do
      get new_post_path
      expect(response.body).to include('New Post')
    end
  end

  describe 'POST /posts' do
    let(:user) { create(:user) }

    context 'with valid params' do
      let(:params) { { post: { title: 'Hello World', user_id: user.id, body: '<p>hello</p>' } } }

      it 'creates a post' do
        expect { post posts_path, params: params }.to change(Post, :count).by(1)
      end

      it 'redirects to the post' do
        post posts_path, params: params
        expect(response).to redirect_to(Post.last)
      end

      it 'enqueues a publish job when publish=1' do
        expect { post posts_path, params: params.merge(publish: '1') }
          .to have_enqueued_job(PostPublishJob)
      end

      it 'does not enqueue publish job without publish=1' do
        expect { post posts_path, params: params }
          .not_to have_enqueued_job(PostPublishJob)
      end

      it 'assigns categories when provided' do
        cat = create(:category)
        post posts_path, params: params.deep_merge(post: { category_ids: [ cat.id ] })
        expect(Post.last.categories).to contain_exactly(cat)
      end
    end

    context 'with invalid params' do
      let(:params) { { post: { title: '', user_id: user.id } } }

      it 'does not create a post' do
        expect { post posts_path, params: params }.not_to change(Post, :count)
      end

      it 'returns 422' do
        post posts_path, params: params
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe 'GET /posts/:id/edit' do
    let(:post_record) { create(:post) }

    it 'returns 200' do
      get edit_post_path(post_record)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'PATCH /posts/:id' do
    let(:post_record) { create(:post, title: 'Old Title') }

    it 'updates the post' do
      patch post_path(post_record), params: { post: { title: 'New Title' } }
      expect(post_record.reload.title).to eq('New Title')
    end

    it 'redirects to the post' do
      patch post_path(post_record), params: { post: { title: 'New Title' } }
      expect(response).to redirect_to(post_record)
    end

    it 'returns 422 with invalid data' do
      patch post_path(post_record), params: { post: { title: '' } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'DELETE /posts/:id' do
    let!(:post_record) { create(:post) }

    it 'destroys the post' do
      expect { delete post_path(post_record) }.to change(Post, :count).by(-1)
    end

    it 'redirects to posts index' do
      delete post_path(post_record)
      expect(response).to redirect_to(posts_path)
    end
  end

  describe 'POST /posts/:id/publish' do
    context 'when draft' do
      let(:post_record) { create(:post, :draft) }

      it 'publishes the post' do
        post publish_post_path(post_record)
        expect(post_record.reload).to be_published
      end

      it 'redirects with published notice' do
        post publish_post_path(post_record)
        follow_redirect!
        expect(flash[:notice]).to eq('Post was published.')
      end
    end

    context 'when already published' do
      let(:post_record) { create(:post, :published) }

      it 'redirects with already-published alert' do
        post publish_post_path(post_record)
        follow_redirect!
        expect(flash[:alert]).to eq('Post was already published.')
      end
    end
  end
end
