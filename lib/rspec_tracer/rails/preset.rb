# frozen_string_literal: true

require 'set'

require_relative '../configuration'

module RSpecTracer
  module Rails
    # Default Rails glob preset - the Coverage-invisible surface that
    # rspec-tracer cannot auto-observe via its standard Ruby-execution
    # tracking. Enabled by `track_rails_defaults` in .rspec-tracer.
    #
    # Covered categories (each toggleable via the `except:` kwarg):
    #
    #   :views     - app/views/**/* (ERB / Slim / Haml / JBuilder)
    #   :helpers   - app/helpers/**/*.rb (tracked as declared so helper
    #                files re-invalidate even before Zeitwerk loads them)
    #   :locales   - config/locales/**/*.yml (I18n data files)
    #   :config    - config/*.yml + config/routes.rb (database.yml,
    #                cable.yml, storage.yml, routes - the YAML + routes
    #                dispatcher are all config surface)
    #   :schema    - db/schema.rb + db/structure.sql
    #   :factories - spec/factories/**/*.rb + test/factories/**/*.rb
    #   :fixtures  - spec/fixtures/**/*.{yml,yaml,json} + same under test/
    #
    # Intentionally omitted:
    #   - Gemfile.lock, .ruby-version, .rspec-tracer: already tracked as
    #     whole-suite invalidators (Tracker::WholeSuiteInvalidators).
    #     Listing them as :declared would cross input-kind categories.
    #   - config/environments/*.rb, config/app_constants.rb: loaded as
    #     Ruby at Rails boot, so LoadedFilesTracker.@boot_set captures
    #     them already as transitive-load inputs.
    #
    # Unknown `except:` keys raise Configuration::InvalidUsageError, same
    # pattern as `storage_backend(:bogus)`.
    class Preset
      DEFAULTS = {
        views: %w[app/views/**/*].freeze,
        helpers: %w[app/helpers/**/*.rb].freeze,
        locales: %w[config/locales/**/*.yml].freeze,
        config: %w[config/*.yml config/routes.rb].freeze,
        schema: %w[db/schema.rb db/structure.sql].freeze,
        factories: %w[spec/factories/**/*.rb test/factories/**/*.rb].freeze,
        fixtures: %w[
          spec/fixtures/**/*.{yml,yaml,json}
          test/fixtures/**/*.{yml,yaml,json}
        ].freeze
      }.freeze

      ALLOWED_KEYS = DEFAULTS.keys.to_set.freeze

      def self.globs(except: [])
        excluded = normalize_excluded(except)
        validate_excluded!(excluded)

        DEFAULTS
          .except(*excluded)
          .values
          .flatten
          .uniq
          .freeze
      end

      def self.normalize_excluded(except)
        Array(except).compact
      end

      def self.validate_excluded!(excluded)
        unknown = excluded.reject { |key| ALLOWED_KEYS.include?(key) }
        return if unknown.empty?

        raise RSpecTracer::Configuration::InvalidUsageError,
              "unknown track_rails_defaults keys: #{unknown.inspect}; " \
              "allowed: #{ALLOWED_KEYS.to_a.inspect}"
      end
    end
  end
end
