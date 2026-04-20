json.extract! post, :id, :title, :slug, :published_at
json.author do
  json.id post.user_id
  json.name post.user.display_name
end
json.url post_url(post, format: :json)
