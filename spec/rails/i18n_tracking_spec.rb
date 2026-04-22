# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'

require 'rspec_tracer/tracker/input'
require 'rspec_tracer/rails/notifications'
require 'rspec_tracer/rails/i18n_tracking'

# Unit spec for RSpecTracer::Rails::I18nTracking. The dev Gemfile does
# not carry I18n, so this spec stubs a minimal I18n::Backend::Base
# surface. The prepend target is a freshly-created Class stubbed into
# the object graph per example, so prepends from one example do not
# persist into the next.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Rails::I18nTracking do
  let(:tmpdir) { Dir.mktmpdir('rspec-tracer-i18n') }
  let(:en_yml) { File.join(tmpdir, 'config/locales/en.yml') }
  let(:es_yml) { File.join(tmpdir, 'config/locales/es.yml') }

  let(:fake_backend_base) do
    Class.new do
      def load_translations(*filenames)
        filenames
      end
    end
  end

  before do
    FileUtils.mkdir_p(File.dirname(en_yml))
    File.write(en_yml, "en:\n  hello: Hello\n")
    File.write(es_yml, "es:\n  hello: Hola\n")

    stub_const('I18n', Module.new)
    stub_const('I18n::Backend', Module.new)
    stub_const('I18n::Backend::Base', fake_backend_base)
  end

  after do
    described_class.uninstall if described_class.installed?
    RSpecTracer::Rails::Notifications.clear_bucket
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  describe '.install / .installed? / .uninstall' do
    it 'is not installed before install is called' do
      expect(described_class).not_to be_installed
    end

    it 'reports installed after install' do
      described_class.install(root: tmpdir)

      expect(described_class).to be_installed
    end

    it 'exposes the expanded root after install' do
      described_class.install(root: tmpdir)

      expect(described_class.root).to eq(File.expand_path(tmpdir))
    end

    it 'prepends LoadTranslationsHook onto I18n::Backend::Base' do
      described_class.install(root: tmpdir)

      expect(I18n::Backend::Base.ancestors).to include(described_class::LoadTranslationsHook)
    end

    it 'no-ops when I18n::Backend::Base is absent' do
      hide_const('I18n::Backend::Base')

      described_class.install(root: tmpdir)

      expect(described_class).to be_installed
    end

    it 'clears installed state on uninstall' do
      described_class.install(root: tmpdir)
      described_class.uninstall

      expect(described_class).not_to be_installed
    end

    it 'is safe to call uninstall without prior install' do
      expect { described_class.uninstall }.not_to raise_error
    end

    it 'swallows errors from Module#prepend during install' do
      allow(I18n::Backend::Base).to receive(:prepend).and_raise(StandardError.new('boom'))

      expect { described_class.install(root: tmpdir) }.not_to raise_error
    end
  end

  describe '#record_translations' do
    before { described_class.install(root: tmpdir) }

    it 'is a no-op when uninstalled' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)
      described_class.uninstall

      described_class.record_translations([en_yml, es_yml])

      expect(bucket).to be_empty
    end

    it 'records every filename in the array' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      described_class.record_translations([en_yml, es_yml])

      expect(bucket.values.map(&:path))
        .to contain_exactly(File.expand_path(en_yml), File.expand_path(es_yml))
    end

    it 'coerces non-array input into an array' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      described_class.record_translations(en_yml)

      expect(bucket.values.map(&:path)).to contain_exactly(File.expand_path(en_yml))
    end

    it 'returns nil regardless of bucket state' do
      expect(described_class.record_translations([])).to be_nil
    end
  end

  describe '#record_translation' do
    before { described_class.install(root: tmpdir) }

    it 'is a no-op when uninstalled' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)
      described_class.uninstall

      described_class.record_translation(en_yml)

      expect(bucket).to be_empty
    end

    it 'is a no-op when no bucket is set' do
      expect { described_class.record_translation(en_yml) }.not_to raise_error
    end

    it 'is a no-op when the path is not string-like' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)
      not_a_path = Object.new
      not_a_path.singleton_class.undef_method(:to_s)

      described_class.record_translation(nil)
      described_class.record_translation(not_a_path)

      expect(bucket).to be_empty
    end

    it 'is a no-op for paths outside the tracked root' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)
      outside = File.expand_path('/tmp/not-under-root.yml')

      described_class.record_translation(outside)

      expect(bucket).to be_empty
    end

    it 'emits a :notification Input with the sha256 digest' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      described_class.record_translation(en_yml)

      input = bucket.values.first
      expect(input.kind).to eq(:notification)
      expect(input.digest).to eq(Digest::SHA256.file(en_yml).hexdigest)
    end

    it 'dedups repeat records for the same path within a bucket' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      3.times { described_class.record_translation(en_yml) }

      expect(bucket.size).to eq(1)
    end

    it 'skips the emission when the filter rejects the path' do
      described_class.uninstall
      described_class.install(root: tmpdir, filter: ->(_path) { false })
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      described_class.record_translation(en_yml)

      expect(bucket).to be_empty
    end

    it 'swallows errors raised by the filter callable' do
      described_class.uninstall
      described_class.install(root: tmpdir, filter: ->(_path) { raise 'filter boom' })
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      expect { described_class.record_translation(en_yml) }.not_to raise_error
      expect(bucket).to be_empty
    end

    it 'swallows errors raised by Digest::SHA256.file' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)

      expect { described_class.record_translation(en_yml) }.not_to raise_error
      expect(bucket).to be_empty
    end
  end

  describe 'LoadTranslationsHook integration' do
    before { described_class.install(root: tmpdir) }

    it 'intercepts load_translations on a Base instance' do
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      I18n::Backend::Base.new.load_translations(en_yml, es_yml)

      expect(bucket.values.map(&:path))
        .to contain_exactly(File.expand_path(en_yml), File.expand_path(es_yml))
    end

    it 'preserves the super return value' do
      RSpecTracer::Rails::Notifications.set_bucket({})

      result = I18n::Backend::Base.new.load_translations(en_yml)

      expect(result).to eq([en_yml])
    end

    it 'intercepts super calls from a subclass' do
      sub = Class.new(I18n::Backend::Base) do
        def load_translations(*filenames)
          super
        end
      end
      bucket = {}
      RSpecTracer::Rails::Notifications.set_bucket(bucket)

      sub.new.load_translations(en_yml)

      expect(bucket.values.map(&:path)).to contain_exactly(File.expand_path(en_yml))
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
