# frozen_string_literal: true

module RSpecTracer
  # The currently installed gem version, in `MAJOR.MINOR.PATCH[.pre.N]`
  # form. Bumped per release; CI's release workflow asserts the tag
  # matches this constant before pushing to RubyGems.
  VERSION = '2.0.0.rc.1'
end
