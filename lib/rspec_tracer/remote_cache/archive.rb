# frozen_string_literal: true

require 'fileutils'
require 'rubygems/package'
require 'zlib'

module RSpecTracer
  module RemoteCache
    # tar+gzip pack/extract for the remote-cache S3 payload. Pure
    # Ruby stdlib (`rubygems/package` + `zlib`) - no shell-out, no
    # new gem deps, works on every supported interpreter (MRI 3.1+
    # and JRuby 9.4 both bundle both modules).
    #
    # Wire format: single `.tar.gz` containing `last_run.json` at the
    # archive root plus a `<run_id>/` directory with the 15 JSON
    # files. Replaces the 1.x per-file layout on S3 (N+1 objects per
    # cache -> 1 object), shrinks payload ~4-6x via gzip on the highly-
    # redundant JSON (shared example IDs across files), and cuts the
    # per-download/upload request count from 15+ to exactly 2
    # (cp for download, cp for upload).
    #
    # Local cache_path layout is UNCHANGED - the archive is pack/unpack
    # boundary for transit only. User-facing filenames in
    # `USER_FACING_SURFACE.md` §6 stay as documented; external tooling
    # that walks `rspec_tracer_cache/` sees the same 15-file layout.
    module Archive
      CACHE_FILENAME = 'cache.tar.gz'

      # Pack the relevant contents of `cache_path` into `dest_path`.
      # Required: `cache_path/last_run.json` and `cache_path/<run_id>/`.
      # Raises ArgumentError on a malformed cache; any I/O error during
      # pack propagates to the caller (S3Backend wraps in S3BackendError
      # + rescues at the orchestrator boundary for graceful degradation).
      def self.pack(cache_path:, run_id:, dest_path:)
        validate_pack_args!(cache_path, run_id, dest_path)
        last_run, run_dir = resolve_pack_sources!(cache_path, run_id)

        File.open(dest_path, 'wb') do |file|
          Zlib::GzipWriter.wrap(file) do |gz|
            Gem::Package::TarWriter.new(gz) do |tar|
              add_file(tar, last_run, 'last_run.json')
              Dir[File.join(run_dir, '*.json')].each do |path|
                add_file(tar, path, File.join(run_id, File.basename(path)))
              end
            end
          end
        end
        dest_path
      end

      def self.validate_pack_args!(cache_path, run_id, dest_path)
        raise ArgumentError, 'cache_path is required' if cache_path.nil? || cache_path.empty?
        raise ArgumentError, 'run_id is required' if run_id.nil? || run_id.empty?
        raise ArgumentError, 'dest_path is required' if dest_path.nil? || dest_path.empty?
      end
      private_class_method :validate_pack_args!

      def self.resolve_pack_sources!(cache_path, run_id)
        last_run = File.join(cache_path, 'last_run.json')
        raise ArgumentError, "missing last_run.json at #{last_run}" unless File.file?(last_run)

        run_dir = File.join(cache_path, run_id)
        raise ArgumentError, "missing run dir at #{run_dir}" unless File.directory?(run_dir)

        [last_run, run_dir]
      end
      private_class_method :resolve_pack_sources!

      # Extract `archive_path` into `dest_dir`. Overwrites existing
      # files (run-dir already present gets replaced). Raises on a
      # malformed archive; caller rescues.
      def self.extract(archive_path:, dest_dir:)
        raise ArgumentError, 'archive_path is required' if archive_path.nil? || archive_path.empty?
        raise ArgumentError, 'dest_dir is required' if dest_dir.nil? || dest_dir.empty?
        raise ArgumentError, "missing archive at #{archive_path}" unless File.file?(archive_path)

        FileUtils.mkdir_p(dest_dir)
        File.open(archive_path, 'rb') do |file|
          Zlib::GzipReader.wrap(file) do |gz|
            Gem::Package::TarReader.new(gz) do |tar|
              tar.each { |entry| write_entry(entry, dest_dir) }
            end
          end
        end
        dest_dir
      end

      # `add_file_simple` (not `add_file`) because Zlib::GzipWriter is
      # non-seekable; the 2-arg `add_file` needs to back-patch the size
      # into the tar header after writing content, which requires
      # `io.pos=`. `add_file_simple` takes the size upfront, writes the
      # header, then streams content - compatible with gzip.
      def self.add_file(tar, local_path, archive_name)
        stat = File.stat(local_path)
        tar.add_file_simple(archive_name, stat.mode & 0o777, stat.size) do |io|
          File.open(local_path, 'rb') { |src| IO.copy_stream(src, io) }
        end
      end
      private_class_method :add_file

      def self.write_entry(entry, dest_dir)
        return unless entry.file?

        safe_name = safe_entry_name(entry.full_name)
        return if safe_name.nil?

        dest = File.join(dest_dir, safe_name)
        FileUtils.mkdir_p(File.dirname(dest))
        File.open(dest, 'wb') { |out| IO.copy_stream(entry, out) }
      end
      private_class_method :write_entry

      # Refuse absolute paths or `..` traversal. Both are illegal in a
      # well-formed cache archive; silently dropping them beats trusting
      # an S3-sourced blob to write anywhere on disk.
      def self.safe_entry_name(name)
        return nil if name.nil? || name.empty?
        return nil if name.start_with?('/')
        return nil if name.split('/').include?('..')

        name
      end
      private_class_method :safe_entry_name
    end
  end
end
