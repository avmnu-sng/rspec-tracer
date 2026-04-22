# frozen_string_literal: true

require 'rspec_tracer/rails/preset'

RSpec.describe RSpecTracer::Rails::Preset do
  describe '.globs' do
    context 'with no exclusions' do
      it 'returns every glob from every DEFAULTS category' do
        globs = described_class.globs

        described_class::DEFAULTS.each_value do |category_globs|
          expect(globs).to include(*category_globs)
        end
      end

      it 'returns a frozen array' do
        expect(described_class.globs).to be_frozen
      end

      it 'contains no duplicate entries' do
        globs = described_class.globs

        expect(globs).to eq(globs.uniq)
      end
    end

    context 'with exclusions' do
      it 'omits every glob of the excluded category' do
        globs = described_class.globs(except: [:views])

        described_class::DEFAULTS[:views].each do |view_glob|
          expect(globs).not_to include(view_glob)
        end
      end

      it 'keeps globs from non-excluded categories' do
        globs = described_class.globs(except: [:views])

        expect(globs).to include(*described_class::DEFAULTS[:locales])
      end

      it 'accepts multiple excluded categories' do
        excluded = %i[views locales]
        globs = described_class.globs(except: excluded)

        excluded_globs = excluded.flat_map { |key| described_class::DEFAULTS[key] }
        expect(globs).not_to include(*excluded_globs)
      end

      it 'coerces a single symbol to a one-element exclusion list' do
        globs = described_class.globs(except: :views)

        described_class::DEFAULTS[:views].each do |view_glob|
          expect(globs).not_to include(view_glob)
        end
      end

      it 'treats nil as no exclusion' do
        expect(described_class.globs(except: nil)).to eq(described_class.globs)
      end

      it 'drops nil entries inside the exclusion list' do
        expect(described_class.globs(except: [nil, :views]))
          .to eq(described_class.globs(except: [:views]))
      end

      it 'raises for an unknown category key' do
        expect { described_class.globs(except: [:bogus]) }
          .to raise_error(
            RSpecTracer::Configuration::InvalidUsageError,
            /unknown track_rails_defaults keys/
          )
      end

      it 'lists every unknown key in the error message' do
        expect { described_class.globs(except: %i[bogus mystery]) }
          .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /:bogus.*:mystery|:mystery.*:bogus/)
      end

      it 'reports allowed keys in the error message' do
        expect { described_class.globs(except: [:bogus]) }
          .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /allowed:/)
      end
    end
  end

  describe 'DEFAULTS constant' do
    it 'defines the seven preset categories' do
      expect(described_class::DEFAULTS.keys)
        .to match_array(%i[views helpers locales config schema factories fixtures])
    end

    it 'is frozen' do
      expect(described_class::DEFAULTS).to be_frozen
    end

    it 'stores frozen glob arrays per category' do
      described_class::DEFAULTS.each_value do |globs|
        expect(globs).to be_frozen
      end
    end

    it 'stores at least one glob in every category' do
      described_class::DEFAULTS.each_value do |globs|
        expect(globs).not_to be_empty
      end
    end
  end

  describe 'ALLOWED_KEYS constant' do
    it 'is a Set instance' do
      expect(described_class::ALLOWED_KEYS).to be_a(Set)
    end

    it 'mirrors DEFAULTS keys' do
      expect(described_class::ALLOWED_KEYS.to_a).to match_array(described_class::DEFAULTS.keys)
    end

    it 'is frozen' do
      expect(described_class::ALLOWED_KEYS).to be_frozen
    end
  end

  describe '.normalize_excluded' do
    it 'wraps a single symbol in an array' do
      expect(described_class.normalize_excluded(:views)).to eq([:views])
    end

    it 'returns [] for nil' do
      expect(described_class.normalize_excluded(nil)).to eq([])
    end

    it 'drops nil entries inside a list' do
      expect(described_class.normalize_excluded([nil, :views, nil])).to eq([:views])
    end

    it 'returns [] for an empty array' do
      expect(described_class.normalize_excluded([])).to eq([])
    end
  end

  describe '.validate_excluded!' do
    it 'returns silently for all-allowed keys' do
      expect { described_class.validate_excluded!(%i[views locales]) }.not_to raise_error
    end

    it 'returns silently for an empty list' do
      expect { described_class.validate_excluded!([]) }.not_to raise_error
    end

    it 'raises when any key is not in ALLOWED_KEYS' do
      expect { described_class.validate_excluded!([:bogus]) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError)
    end
  end
end
