# frozen_string_literal: true

module RSpecTracer
  module Tracker
    # Wildcard env matching helper.
    #
    # Lives outside Configuration so configure's alias loop does not
    # leak its private helpers as public _name DSL surface
    # (memory: feedback_configure_dsl_private_leak). Pure utility
    # module; def self.x style for mutant observability
    # (memory: feedback_mutation_friendly_modules). ASCII-only source
    # (memory: feedback_mutant_non_ascii_source).
    #
    # Patterns accepted:
    #   - Literal env name              "AUTH_TOKEN"
    #   - Single trailing wildcard      "RAILS_*"
    #   - Single leading wildcard       "*_TOKEN"
    #   - Bare wildcard (matches all)   "*"
    #
    # Patterns rejected (raise ArgumentError):
    #   - Multi-segment / embedded *    "RAILS_*_ENV"
    #   - Multiple *                    "RAILS_*_*"
    #   - Character classes             "RAILS_[A-Z]*"
    #   - Negation / glob escape        "RAILS_!ENV", "RAILS_\X"
    #   - Question mark                 "RAILS_?ENV"
    #   - Empty / nil
    module EnvMatcher
      WILDCARD = '*'
      DISALLOWED_CHARS = %w[? [ ] ! \\].freeze

      # Boolean: does the pattern contain at least one wildcard?
      def self.wildcard?(pattern)
        pattern.to_s.include?(WILDCARD)
      end

      # Expand a list of patterns against env keys. Literals pass
      # through; wildcards are anchored + grepped against env.keys.
      # Returns a deduped Array<String> in input order.
      #
      # `env` is injectable for testability; defaults to ::ENV. Reads
      # only env.keys, never values.
      def self.expand(patterns, env: ::ENV)
        result = []
        patterns.each do |pattern|
          str = pattern.to_s
          validate!(str)
          if wildcard?(str)
            re = glob_to_regex(str)
            env.each_key { |k| result << k if re.match?(k) }
          else
            result << str
          end
        end
        result.uniq
      end

      # Boolean: does `name` match `pattern`? Single-pattern variant
      # of expand for ad-hoc checks (specs, future call sites). Named
      # `match_glob?` (predicate suffix) per Naming/PredicateMethod.
      def self.match_glob?(pattern, name)
        str = pattern.to_s
        validate!(str)
        return str == name.to_s unless wildcard?(str)

        glob_to_regex(str).match?(name.to_s)
      end

      # Raise ArgumentError on unsupported pattern syntax. Called
      # before any regex build so users see a clear message at
      # config-load time (Engine#setup) or at RunnerHook Pass 1
      # (per-example metadata) rather than a regex parse crash.
      # rubocop:disable Metrics/PerceivedComplexity
      def self.validate!(pattern)
        if pattern.nil? || pattern.empty?
          raise ArgumentError,
                "track_env pattern must be a non-empty String (got #{pattern.inspect})"
        end

        DISALLOWED_CHARS.each do |c|
          next unless pattern.include?(c)

          raise ArgumentError,
                "track_env pattern #{pattern.inspect} contains unsupported character " \
                "#{c.inspect} (allowed: literals, single trailing/leading *)"
        end

        return if pattern == WILDCARD

        stars = pattern.count(WILDCARD)
        return if stars.zero?

        if stars > 1
          raise ArgumentError,
                "track_env pattern #{pattern.inspect} contains multiple wildcards " \
                '(only one * is allowed, at the start or end)'
        end

        return if pattern.start_with?(WILDCARD) || pattern.end_with?(WILDCARD)

        raise ArgumentError,
              "track_env pattern #{pattern.inspect} has an embedded wildcard " \
              '(only single trailing/leading * is supported, e.g. PREFIX_* or *_SUFFIX)'
      end
      # rubocop:enable Metrics/PerceivedComplexity

      # Build an anchored regex from a wildcard pattern. `*` becomes
      # `[^=]*` (env names contain no `=` by Posix; defensive). Anchors
      # are mandatory or "RAILS_*" would match "MY_RAILS_THING".
      # Private singleton helper - exposed only via match_glob / expand.
      class << self
        private

        def glob_to_regex(pattern)
          /\A#{Regexp.escape(pattern).gsub('\\*', '[^=]*')}\z/
        end
      end
    end
  end
end
