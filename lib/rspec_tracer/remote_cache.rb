# frozen_string_literal: true

# Entry point for the `rspec-tracer/remote_cache` namespace. Loaded
# lazily by the user-facing Rakefile shim at
# `lib/rspec_tracer/remote_cache/Rakefile`, not by the main
# `rspec_tracer` gem load. Test-suite runs that never invoke the
# remote-cache Rake tasks pay zero cost for this subtree.

require_relative 'remote_cache/backend'
require_relative 'remote_cache/validator'
require_relative 'remote_cache/git_ancestry'
require_relative 'remote_cache/local_fs_backend'
require_relative 'remote_cache/redis_backend'
require_relative 'remote_cache/s3_backend'
require_relative 'remote_cache/user_tasks'

module RSpecTracer
  module RemoteCache
  end
end
