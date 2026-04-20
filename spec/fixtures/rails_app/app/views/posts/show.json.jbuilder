json.partial! "post", post: @post
json.body @post.body.to_plain_text
json.categories(@post.categories) do |category|
  json.extract! category, :id, :name, :slug
end
json.comments_count @post.comment_count
