# frozen_string_literal: true

# Idempotent seeds for local poke-around and spec boot sanity.
# Production-equivalent seeding is out of scope for a test fixture.

%w[news tutorials opinion announcements].each do |slug|
  Category.find_or_create_by!(slug: slug) do |c|
    c.name = slug.titleize
  end
end

admin = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.name = 'Admin User'
  u.role = 'admin'
  u.activated_at = Time.current
end

author = User.find_or_create_by!(email: 'author@example.com') do |u|
  u.name = 'Author User'
  u.role = 'member'
  u.activated_at = Time.current
end

Post.find_or_create_by!(slug: 'welcome') do |p|
  p.user = admin
  p.title = 'Welcome'
  p.body = '<p>Hello from the reference Rails fixture.</p>'
  p.published_at = Time.current
  p.categories << Category.find_by!(slug: 'announcements')
end

Post.find_or_create_by!(slug: 'first-tutorial') do |p|
  p.user = author
  p.title = 'First Tutorial'
  p.body = '<p>A sample tutorial post.</p>'
  p.categories << Category.find_by!(slug: 'tutorials')
end
