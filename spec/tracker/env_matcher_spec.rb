# frozen_string_literal: true

require 'rspec_tracer/tracker/env_matcher'

RSpec.describe RSpecTracer::Tracker::EnvMatcher do
  describe '.wildcard?' do
    it 'is true for a trailing-wildcard pattern' do
      expect(described_class.wildcard?('RAILS_*')).to be(true)
    end

    it 'is true for a leading-wildcard pattern' do
      expect(described_class.wildcard?('*_TOKEN')).to be(true)
    end

    it 'is true for the bare wildcard' do
      expect(described_class.wildcard?('*')).to be(true)
    end

    it 'is false for a literal pattern' do
      expect(described_class.wildcard?('AUTH_TOKEN')).to be(false)
    end

    it 'coerces non-String input via to_s' do
      expect(described_class.wildcard?(:RAILS_ENV)).to be(false)
    end
  end

  describe '.expand' do
    let(:env) do
      {
        'RAILS_ENV' => 'test',
        'RAILS_MAX_THREADS' => '5',
        'DATABASE_URL' => 'postgres://',
        'AWS_ACCESS_KEY_ID' => 'k',
        'AWS_SECRET_ACCESS_KEY' => 's'
      }
    end

    it 'returns an empty Array when patterns is empty' do
      expect(described_class.expand([], env: env)).to eq([])
    end

    it 'passes literal patterns through unchanged' do
      expect(described_class.expand(['DATABASE_URL'], env: env)).to eq(['DATABASE_URL'])
    end

    it 'passes literals through even when not present in env' do
      expect(described_class.expand(['NOT_IN_ENV'], env: env)).to eq(['NOT_IN_ENV'])
    end

    it 'expands a trailing-wildcard pattern against env.keys' do
      expect(described_class.expand(['RAILS_*'], env: env))
        .to contain_exactly('RAILS_ENV', 'RAILS_MAX_THREADS')
    end

    it 'expands a leading-wildcard pattern against env.keys' do
      expect(described_class.expand(['*_KEY_ID'], env: env))
        .to contain_exactly('AWS_ACCESS_KEY_ID')
    end

    it 'expands the bare wildcard to every env key' do
      expect(described_class.expand(['*'], env: env)).to match_array(env.keys)
    end

    it 'returns an empty Array when a wildcard matches no env keys' do
      expect(described_class.expand(['MY_RAILS_*'], env: env)).to eq([])
    end

    it 'is anchored at both ends (no implicit substring match)' do
      # Without \A...\z, "RAILS_*" would also match "MY_RAILS_X". With
      # anchors, it does not.
      env_with_prefix = env.merge('MY_RAILS_THING' => 'x')

      expect(described_class.expand(['RAILS_*'], env: env_with_prefix))
        .not_to include('MY_RAILS_THING')
    end

    it 'dedupes literal patterns repeated across the input list' do
      expect(described_class.expand(%w[A B A B A], env: env)).to eq(%w[A B])
    end

    it 'dedupes literals that also match a sibling wildcard pattern' do
      # 'RAILS_ENV' explicit + 'RAILS_*' wildcard expansion both produce
      # 'RAILS_ENV'; the result should contain it once.
      result = described_class.expand(['RAILS_ENV', 'RAILS_*'], env: env)

      expect(result.count('RAILS_ENV')).to eq(1)
    end

    it 'preserves input order for literals + wildcard expansions' do
      result = described_class.expand(['DATABASE_URL', 'RAILS_*'], env: env)

      expect(result.first).to eq('DATABASE_URL')
    end

    it 'coerces non-String entries via to_s' do
      expect(described_class.expand([:DATABASE_URL], env: env)).to eq(['DATABASE_URL'])
    end

    it 'defaults env: to ::ENV when no kwarg is given' do
      stub_const('ENV', { 'RSPEC_TRACER_ENV_MATCHER_PROBE' => 'on' })

      expect(described_class.expand(['RSPEC_TRACER_ENV_*']))
        .to eq(['RSPEC_TRACER_ENV_MATCHER_PROBE'])
    end

    it 'raises ArgumentError on a multi-wildcard pattern' do
      expect { described_class.expand(['A_*_*'], env: env) }
        .to raise_error(ArgumentError, /multiple wildcards/)
    end

    it 'raises ArgumentError on an embedded wildcard' do
      expect { described_class.expand(['RAILS_*_ENV'], env: env) }
        .to raise_error(ArgumentError, /embedded wildcard/)
    end

    it 'raises ArgumentError on a question-mark glob' do
      expect { described_class.expand(['RAILS_?'], env: env) }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises ArgumentError on a character class' do
      expect { described_class.expand(['RAILS_[A-Z]*'], env: env) }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises ArgumentError on negation' do
      expect { described_class.expand(['RAILS_!ENV'], env: env) }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises ArgumentError on backslash escape' do
      expect { described_class.expand(['RAILS_\\X'], env: env) }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises ArgumentError on an empty string' do
      expect { described_class.expand([''], env: env) }
        .to raise_error(ArgumentError, /non-empty String/)
    end

    it 'raises ArgumentError on nil' do
      expect { described_class.expand([nil], env: env) }
        .to raise_error(ArgumentError, /non-empty String/)
    end
  end

  describe '.match_glob?' do
    it 'is true for a literal pattern equal to name' do
      expect(described_class.match_glob?('AUTH_TOKEN', 'AUTH_TOKEN')).to be(true)
    end

    it 'is false for a literal pattern unequal to name' do
      expect(described_class.match_glob?('AUTH_TOKEN', 'OTHER')).to be(false)
    end

    it 'is true for a trailing-wildcard pattern that matches name' do
      expect(described_class.match_glob?('RAILS_*', 'RAILS_ENV')).to be(true)
    end

    it 'is false for a trailing-wildcard pattern that does not match name' do
      expect(described_class.match_glob?('RAILS_*', 'DATABASE_URL')).to be(false)
    end

    it 'is true for a leading-wildcard pattern that matches name' do
      expect(described_class.match_glob?('*_TOKEN', 'AUTH_TOKEN')).to be(true)
    end

    it 'is false for a leading-wildcard pattern that does not match name' do
      expect(described_class.match_glob?('*_TOKEN', 'AUTH_KEY')).to be(false)
    end

    it 'is true for the bare wildcard against any non-empty name' do
      expect(described_class.match_glob?('*', 'X')).to be(true)
    end

    it 'is anchored - "RAILS_*" does not match "MY_RAILS_X"' do
      expect(described_class.match_glob?('RAILS_*', 'MY_RAILS_X')).to be(false)
    end

    it 'coerces both pattern and name via to_s' do
      expect(described_class.match_glob?(:'RAILS_*', :RAILS_ENV)).to be(true)
    end

    it 'raises ArgumentError on an unsupported pattern' do
      expect { described_class.match_glob?('RAILS_*_ENV', 'RAILS_FOO_ENV') }
        .to raise_error(ArgumentError)
    end
  end

  describe '.validate!' do
    it 'returns nil for a literal' do
      expect(described_class.validate!('AUTH_TOKEN')).to be_nil
    end

    it 'returns nil for a trailing-wildcard pattern' do
      expect(described_class.validate!('RAILS_*')).to be_nil
    end

    it 'returns nil for a leading-wildcard pattern' do
      expect(described_class.validate!('*_TOKEN')).to be_nil
    end

    it 'returns nil for the bare wildcard' do
      expect(described_class.validate!('*')).to be_nil
    end

    it 'raises on an empty string' do
      expect { described_class.validate!('') }
        .to raise_error(ArgumentError, /non-empty String/)
    end

    it 'raises on nil' do
      expect { described_class.validate!(nil) }
        .to raise_error(ArgumentError, /non-empty String/)
    end

    it 'raises on multiple wildcards' do
      expect { described_class.validate!('A_*_B_*') }
        .to raise_error(ArgumentError, /multiple wildcards/)
    end

    it 'raises on an embedded wildcard' do
      expect { described_class.validate!('A_*_B') }
        .to raise_error(ArgumentError, /embedded wildcard/)
    end

    it 'raises on `?`' do
      expect { described_class.validate!('A_?') }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises on `[`' do
      expect { described_class.validate!('A_[Z]') }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises on `]`' do
      expect { described_class.validate!('A_]') }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises on `!`' do
      expect { described_class.validate!('!FOO') }
        .to raise_error(ArgumentError, /unsupported character/)
    end

    it 'raises on `\\`' do
      expect { described_class.validate!('A\\B') }
        .to raise_error(ArgumentError, /unsupported character/)
    end
  end
end
