# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'

require 'rspec_tracer/tracker/input'
require 'rspec_tracer/rails/notifications'

# Unit spec for RSpecTracer::Rails::Notifications. The dev Gemfile does
# not carry Rails / ActiveSupport, so this spec stubs a minimal
# AS::Notifications surface that records subscribe / unsubscribe /
# publish calls. Full real-Rails fixture boot is integration-matrix territory.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Rails::Notifications do
  let(:tmpdir) { Dir.mktmpdir('rspec-tracer-notifications') }
  let(:template_path) { File.join(tmpdir, 'app/views/users/show.erb') }
  let(:schema_rb) { File.join(tmpdir, 'db/schema.rb') }
  let(:structure_sql) { File.join(tmpdir, 'db/structure.sql') }

  # Lightweight AS::Notifications stand-in. Every subscribe call
  # records (event_name, block) and returns a unique handle; publish
  # fires every block keyed on the event name (a real subscriber can
  # attach multiple blocks per event). Unsubscribe drops the handle.
  let(:fake_notifications) do
    Class.new do
      def initialize
        @subscribers = {}
      end

      def subscribe(event_name, &block)
        handle = Object.new
        (@subscribers[event_name] ||= {})[handle] = block
        handle
      end

      def unsubscribe(handle)
        @subscribers.each_value { |blocks| blocks.delete(handle) }
      end

      def publish(event_name, payload)
        blocks = @subscribers[event_name] || {}
        blocks.each_value { |b| b.call(event_name, Time.now, Time.now, 'id', payload) }
      end

      def subscribed_event_names
        @subscribers.keys
      end

      def subscriber_count
        @subscribers.values.sum(&:size)
      end
    end.new
  end

  before do
    FileUtils.mkdir_p(File.dirname(template_path))
    File.write(template_path, '<h1>users#show</h1>')
    FileUtils.mkdir_p(File.join(tmpdir, 'db'))
    File.write(schema_rb, "ActiveRecord::Schema.define { }\n")

    stub_const('ActiveSupport', Module.new)
    stub_const('ActiveSupport::Notifications', fake_notifications)
    stub_const('Rails', Module.new) unless defined?(Rails)
    stub_const('Rails::VERSION', Module.new)
    stub_const('Rails::VERSION::STRING', '7.2.3.1')
  end

  after do
    described_class.uninstall if described_class.installed?
    described_class.clear_bucket
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  describe '.install / .installed? / .uninstall' do
    it 'is not installed before install is called' do
      expect(described_class).not_to be_installed
    end

    it 'is installed after install' do
      described_class.install(root: tmpdir)

      expect(described_class).to be_installed
    end

    it 'reports the expanded root after install' do
      described_class.install(root: tmpdir)

      expect(described_class.root).to eq(File.expand_path(tmpdir))
    end

    it 'subscribes to render_template.action_view' do
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).to include('render_template.action_view')
    end

    it 'subscribes to render_partial.action_view' do
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).to include('render_partial.action_view')
    end

    it 'subscribes to render_collection.action_view on Rails 7.1+' do
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).to include('render_collection.action_view')
    end

    it 'skips render_collection subscription when Rails < 7.1' do
      stub_const('Rails::VERSION::STRING', '7.0.8')
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).not_to include('render_collection.action_view')
    end

    it 'skips render_collection subscription when Rails::VERSION::STRING is absent' do
      stub_const('Rails::VERSION', Module.new)
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).not_to include('render_collection.action_view')
    end

    it 'skips render_collection subscription when VERSION parsing raises' do
      stub_const('Rails::VERSION::STRING', Object.new)
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).not_to include('render_collection.action_view')
    end

    it 'does not subscribe to sql.active_record with no ar_schema_paths' do
      described_class.install(root: tmpdir)

      expect(fake_notifications.subscribed_event_names).not_to include('sql.active_record')
    end

    it 'subscribes to sql.active_record when ar_schema_paths resolves inputs' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])

      expect(fake_notifications.subscribed_event_names).to include('sql.active_record')
    end

    it 'does not subscribe to sql.active_record when every ar_schema_paths entry is missing' do
      described_class.install(root: tmpdir, ar_schema_paths: [File.join(tmpdir, 'db/missing.rb')])

      expect(fake_notifications.subscribed_event_names).not_to include('sql.active_record')
    end

    it 'resets installed state after uninstall' do
      described_class.install(root: tmpdir)
      described_class.uninstall

      expect(described_class).not_to be_installed
    end

    it 'unsubscribes every stored handle on uninstall' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      described_class.uninstall

      expect(fake_notifications.subscriber_count).to eq(0)
    end

    it 'is safe to call uninstall without prior install' do
      expect { described_class.uninstall }.not_to raise_error
    end

    it 'swallows errors from an individual unsubscribe call' do
      described_class.install(root: tmpdir)
      allow(fake_notifications).to receive(:unsubscribe).and_raise(StandardError.new('boom'))

      expect { described_class.uninstall }.not_to raise_error
    end
  end

  describe 'bucket lifecycle' do
    before { described_class.install(root: tmpdir) }

    it 'returns nil current_bucket before set_bucket' do
      expect(described_class.current_bucket).to be_nil
    end

    it 'exposes the bucket via current_bucket after set_bucket' do
      bucket = {}
      described_class.set_bucket(bucket)

      expect(described_class.current_bucket).to be(bucket)
    end

    it 'clears the bucket on clear_bucket' do
      described_class.set_bucket({})
      described_class.clear_bucket

      expect(described_class.current_bucket).to be_nil
    end
  end

  describe '#handle_render_event' do
    before { described_class.install(root: tmpdir) }

    it 'returns nil for a non-hash payload' do
      expect(described_class.handle_render_event('oops')).to be_nil
    end

    it 'returns nil for a payload with no identifier key' do
      expect(described_class.handle_render_event({})).to be_nil
    end

    it 'records the template path from a symbol-keyed payload' do
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.handle_render_event({ identifier: template_path })

      expect(bucket.values.map(&:path)).to contain_exactly(File.expand_path(template_path))
    end

    it 'records the template path from a string-keyed payload' do
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.handle_render_event({ 'identifier' => template_path })

      expect(bucket.values.map(&:path)).to contain_exactly(File.expand_path(template_path))
    end

    it 'prefers the symbol key when both shapes are present' do
      bucket = {}
      described_class.set_bucket(bucket)
      other = File.join(tmpdir, 'app/views/users/edit.erb')
      File.write(other, '<h1>edit</h1>')

      described_class.handle_render_event({ identifier: template_path, 'identifier' => other })

      expect(bucket.values.map(&:path)).to contain_exactly(File.expand_path(template_path))
    end
  end

  describe '#record_template' do
    before { described_class.install(root: tmpdir) }

    it 'is a no-op when uninstalled' do
      bucket = {}
      described_class.set_bucket(bucket)
      described_class.uninstall

      described_class.record_template(template_path)

      expect(bucket).to be_empty
    end

    it 'is a no-op when no bucket is set' do
      expect { described_class.record_template(template_path) }.not_to raise_error
    end

    it 'is a no-op when the path is not a string-like' do
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_template(nil)
      described_class.record_template(Object.new.tap { |o| o.singleton_class.undef_method(:to_s) })

      expect(bucket).to be_empty
    end

    it 'is a no-op for paths outside the tracked root' do
      bucket = {}
      described_class.set_bucket(bucket)
      outside = File.expand_path('/tmp/not-under-root.erb')

      described_class.record_template(outside)

      expect(bucket).to be_empty
    end

    it 'emits a :template Input with the sha256 digest' do
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_template(template_path)

      input = bucket.values.first
      expect(input.kind).to eq(:template)
      expect(input.digest).to eq(Digest::SHA256.file(template_path).hexdigest)
    end

    it 'dedups repeat emissions for the same path within one bucket' do
      bucket = {}
      described_class.set_bucket(bucket)

      3.times { described_class.record_template(template_path) }

      expect(bucket.size).to eq(1)
    end

    it 'skips the emission when the filter rejects the path' do
      described_class.uninstall
      described_class.install(root: tmpdir, filter: ->(_path) { false })
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_template(template_path)

      expect(bucket).to be_empty
    end

    it 'swallows errors raised by the filter callable' do
      described_class.uninstall
      described_class.install(root: tmpdir, filter: ->(_path) { raise 'filter boom' })
      bucket = {}
      described_class.set_bucket(bucket)

      expect { described_class.record_template(template_path) }.not_to raise_error
      expect(bucket).to be_empty
    end

    it 'swallows errors from Digest::SHA256.file' do
      bucket = {}
      described_class.set_bucket(bucket)
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)

      expect { described_class.record_template(template_path) }.not_to raise_error
      expect(bucket).to be_empty
    end
  end

  describe 'render subscriber integration via fake AS::Notifications' do
    before { described_class.install(root: tmpdir) }

    it 'records a template when render_template.action_view fires' do
      bucket = {}
      described_class.set_bucket(bucket)

      fake_notifications.publish('render_template.action_view', { identifier: template_path })

      expect(bucket.values.map(&:kind)).to contain_exactly(:template)
    end

    it 'records a template when render_partial.action_view fires' do
      bucket = {}
      described_class.set_bucket(bucket)

      fake_notifications.publish('render_partial.action_view', { identifier: template_path })

      expect(bucket.values.map(&:kind)).to contain_exactly(:template)
    end

    it 'records a template when render_collection.action_view fires' do
      bucket = {}
      described_class.set_bucket(bucket)

      fake_notifications.publish('render_collection.action_view', { identifier: template_path })

      expect(bucket.values.map(&:kind)).to contain_exactly(:template)
    end
  end

  describe '#record_ar_schema' do
    it 'is a no-op when ar_schema_inputs was never built' do
      described_class.install(root: tmpdir)
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_ar_schema

      expect(bucket).to be_empty
    end

    it 'is a no-op when no bucket is set' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])

      expect { described_class.record_ar_schema }.not_to raise_error
    end

    it 'emits each schema input on the first event' do
      File.write(structure_sql, "-- schema\n")
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb, structure_sql])
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_ar_schema

      expect(bucket.values.map(&:path))
        .to contain_exactly(File.expand_path(schema_rb), File.expand_path(structure_sql))
    end

    it 'emits schema inputs with kind :notification' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_ar_schema

      expect(bucket.values.map(&:kind)).to contain_exactly(:notification)
    end

    it 'short-circuits on the second call within the same bucket' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      bucket = {}
      described_class.set_bucket(bucket)
      described_class.record_ar_schema
      digest_before = bucket.values.first.digest

      File.write(schema_rb, 'NEW')
      described_class.record_ar_schema

      expect(bucket.values.first.digest).to eq(digest_before)
    end

    it 'fires again after clear_bucket + set_bucket with a fresh bucket' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      described_class.set_bucket({})
      described_class.record_ar_schema
      described_class.clear_bucket

      bucket_b = {}
      described_class.set_bucket(bucket_b)
      described_class.record_ar_schema

      expect(bucket_b).not_to be_empty
    end

    it 'drops ar_schema_paths entries outside the tracked root' do
      outside = File.join(Dir.tmpdir, 'foreign-schema.rb')
      File.write(outside, 'x')
      described_class.install(root: tmpdir, ar_schema_paths: [outside, schema_rb])
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.record_ar_schema

      expect(bucket.values.map(&:path)).to contain_exactly(File.expand_path(schema_rb))
    ensure
      FileUtils.rm_f(outside)
    end

    it 'drops ar_schema_paths entries whose digest build raises' do
      allow(Digest::SHA256).to receive(:file).and_raise(StandardError.new('digest fail'))

      expect { described_class.install(root: tmpdir, ar_schema_paths: [schema_rb]) }.not_to raise_error
      expect(described_class.instance_variable_get(:@ar_schema_inputs)).to be_empty
    end

    it 'drops ar_schema_paths entries whose digest compute returns nil (e.g. racey delete)' do
      allow(RSpecTracer::Tracker::FileDigest).to receive(:compute).and_return(nil)

      expect { described_class.install(root: tmpdir, ar_schema_paths: [schema_rb]) }.not_to raise_error
      expect(described_class.instance_variable_get(:@ar_schema_inputs)).to be_empty
    end

    it 'swallows errors inside record_ar_schema' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      bucket = {}
      described_class.set_bucket(bucket)
      bucket.define_singleton_method(:[]=) { |*| raise 'bucket write boom' }

      expect { described_class.record_ar_schema }.not_to raise_error
    end
  end

  describe 'sql.active_record subscriber integration' do
    it 'fires record_ar_schema when sql.active_record is published' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      bucket = {}
      described_class.set_bucket(bucket)

      fake_notifications.publish('sql.active_record', { sql: 'SELECT 1' })

      expect(bucket.values.map(&:kind)).to contain_exactly(:notification)
    end

    it 'does not fire when no bucket is set' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])

      expect { fake_notifications.publish('sql.active_record', {}) }.not_to raise_error
    end
  end

  describe '#handle_sql_event' do
    it 'delegates to record_ar_schema regardless of payload shape' do
      described_class.install(root: tmpdir, ar_schema_paths: [schema_rb])
      bucket = {}
      described_class.set_bucket(bucket)

      described_class.handle_sql_event(nil)

      expect(bucket).not_to be_empty
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
