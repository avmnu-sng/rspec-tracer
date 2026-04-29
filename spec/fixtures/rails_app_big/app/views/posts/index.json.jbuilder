json.posts(@posts) do |post|
  json.partial! "post", post: post
end
json.meta do
  json.count @posts.size
  json.generated_at Time.current.iso8601
end
