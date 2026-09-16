require "rubygems/package"
require "zlib"

module Registry
  # Safely inspects an uploaded .tar.gz without trusting it: enforces size and
  # entry limits, rejects symlinks/hardlinks/devices, absolute paths, and path
  # traversal. Never extracts to disk — reads manifest and readme in memory.
  class TarballInspector
    class InvalidTarball < StandardError; end

    MAX_TARBALL_BYTES = 10.megabytes
    MAX_UNPACKED_BYTES = 50.megabytes
    MAX_ENTRIES = 2_000
    MAX_THEME_TARBALL_BYTES = 50.megabytes
    MAX_THEME_UNPACKED_BYTES = 150.megabytes
    RESERVED_NAMES = %w[.registry-receipt.json .local-origin.json].freeze
    MANIFEST_NAME = "manifest.json"
    README_CANDIDATES = %w[README.md readme.md README Readme.md].freeze
    # Four ordered screenshot slots; the original `preview` is an alias for
    # slot 1. Full bytes are retained, within a per-image and four-image cap.
    PREVIEW_PATTERN = /\Apreview([1-4])?\.(png|jpg|jpeg|webp|gif)\z/
    NUMBERED_PREVIEW_PATTERN = /\Apreview[0-9]+\.(png|jpg|jpeg|webp|gif)\z/
    MAX_PREVIEW_BYTES = 10.megabytes

    # Per-file cap on content retained for scanning; larger files keep only
    # their first MAX_SCAN_BYTES (the scanner flags oversized/binary blobs anyway).
    MAX_SCAN_BYTES = 512.kilobytes

    attr_reader :manifest, :readme, :files, :contents, :digests, :truncated, :sha256, :size_bytes,
      :preview_name, :preview_bytes, :previews, :payload_markers, :modes, :sizes

    def self.inspect_bytes(bytes)
      new(bytes).tap(&:inspect!)
    end

    def initialize(bytes)
      @bytes = bytes
    end

    def inspect!
      @size_bytes = @bytes.bytesize
      raise InvalidTarball, "tarball is empty" if @size_bytes.zero?
      raise InvalidTarball, "tarball exceeds #{MAX_THEME_TARBALL_BYTES / 1.megabyte}MB limit" if @size_bytes > MAX_THEME_TARBALL_BYTES

      @sha256 = Digest::SHA256.hexdigest(@bytes)
      @files = []
      @modes = {}
      @contents = {}
      @payload_markers = {}
      @digests = {} # full-content SHA-256 per file — diffing must never rely on the truncated scan window
      @sizes = {}
      @truncated = []
      @directories = Set.new
      manifest_json = nil
      readme_content = nil
      previews = {}
      unpacked = 0

      entry_count = 0
      each_tar_entry do |entry|
        # Count EVERY entry (directories included) so an archive can't smuggle
        # unbounded headers past a files-only limit.
        entry_count += 1
        raise InvalidTarball, "too many entries" if entry_count > MAX_ENTRIES

        path = clean_path(entry.full_name)
        raise InvalidTarball, "git metadata is not a release payload" if path.split("/").include?(".git")
        # Every entry's declared size counts against the cap BEFORE any type
        # skip — a "directory" with a payload still costs decompression work.
        unpacked += entry.header.size
        raise InvalidTarball, "unpacked size exceeds limit" if unpacked > MAX_THEME_UNPACKED_BYTES

        case
        when entry.directory?
          # Tracked so an explicit directory entry can't collide with a file
          @directories << path
          next
        when entry.header.typeflag == "x"
          # Per-file PAX headers can rewrite what an extractor produces
          # (path, linkpath, sparse maps, …) — the served bytes keep them, so
          # none are allowed. Plugins never legitimately need them.
          raise InvalidTarball, "per-file PAX extended headers are not allowed"
        when entry.header.typeflag == "g"
          # Global PAX header: git archive always emits one comment record.
          # Allowlist exactly that — every other key could affect extraction.
          pax = entry.read.to_s
          unless pax.split("\n").reject(&:empty?).all? { |record| record.match?(/\A\d+ comment=/) }
            raise InvalidTarball, "global PAX header may only carry a comment"
          end
          next
        when entry.symlink? || entry.header.typeflag == "1"
          raise InvalidTarball, "symlinks and hardlinks are not allowed (#{path})"
        when !entry.file?
          raise InvalidTarball, "unsupported entry type for #{path}"
        end

        # Duplicate paths would let reviewed bytes differ from unpacked bytes
        # depending on which entry a consumer picks — never ambiguous.
        raise InvalidTarball, "duplicate path in tarball: #{path}" if @contents.key?(path)

        @files << path
        raise InvalidTarball, "reserved client metadata: #{path}" if RESERVED_NAMES.include?(path)
        raise InvalidTarball, "privileged file mode: #{path}" unless (entry.header.mode & 0o6000).zero?
        @modes[path] = entry.header.mode
        preview_match = PREVIEW_PATTERN.match(path)
        if NUMBERED_PREVIEW_PATTERN.match?(path) && !preview_match
          raise InvalidTarball, "screenshots must use preview1 through preview4"
        end
        if preview_match
          slot = (preview_match[1] || "1").to_i
          raise InvalidTarball, "multiple preview images for slot #{slot}; use one format per slot (preview aliases preview1)" if previews.key?(slot)
          raise InvalidTarball, "#{path} exceeds 10MB" if entry.header.size > MAX_PREVIEW_BYTES
        end
        content = entry.read.to_s
        @sizes[path] = content.bytesize
        @digests[path] = Digest::SHA256.hexdigest(content)
        @truncated << path if content.bytesize > MAX_SCAN_BYTES
        # Executable-payload markers over the FULL bytes, computed here because
        # only the first MAX_SCAN_BYTES are retained — an appended payload past
        # the scan window must not escape by hiding in the truncated tail.
        markers = []
        markers << "elf-executable" if content.match?(/\x7fELF/n)
        markers << "pe-executable" if content.match?(/(?<!\A)MZ\x90\x00/n)
        markers << "embedded-shebang" if content.match?(%r{\n#!\s*/(bin|usr)/}n)
        @payload_markers[path] = markers if markers.any?
        @contents[path] = content.byteslice(0, MAX_SCAN_BYTES)
        manifest_json = content if path == MANIFEST_NAME
        readme_content ||= content.dup.force_encoding(Encoding::UTF_8) if README_CANDIDATES.include?(path)
        previews[slot] = [ path, content ] if preview_match
      end

      # A file whose path is also a directory prefix of another entry can't be
      # extracted by any normal tool — an unextractable archive must never
      # become an immutable release.
      file_set = @files.to_set
      @files.each do |candidate|
        raise InvalidTarball, "path conflict: #{candidate} is both a file and a directory" if @directories.include?(candidate)
        prefix = candidate.rpartition("/").first
        until prefix.empty?
          raise InvalidTarball, "path conflict: #{prefix} is both a file and a directory" if file_set.include?(prefix)
          prefix = prefix.rpartition("/").first
        end
      end

      raise InvalidTarball, "#{MANIFEST_NAME} missing at tarball root" if manifest_json.nil?
      @manifest = parse_manifest(manifest_json)
      unless @manifest["packageType"] == "theme"
        raise InvalidTarball, "tarball exceeds #{MAX_TARBALL_BYTES / 1.megabyte}MB limit" if @size_bytes > MAX_TARBALL_BYTES
        raise InvalidTarball, "unpacked size exceeds limit" if unpacked > MAX_UNPACKED_BYTES
      end
      @readme = readme_content&.valid_encoding? ? readme_content : nil
      @previews = previews.sort.map(&:last).to_h
      @preview_name, @preview_bytes = @previews.first
      self
    rescue Zlib::Error, Gem::Package::TarInvalidError => e
      raise InvalidTarball, "not a valid gzipped tarball: #{e.message}"
    end

    def include?(path) = files.include?(path)

    private

    # Only NUL padding may follow the tar terminator, and not much of it —
    # anything else is a smuggling attempt (and an unbounded drain would be a
    # decompression bomb of its own).
    MAX_TRAILING_PADDING = 64 * 1024

    def each_tar_entry(&block)
      Zlib::GzipReader.wrap(StringIO.new(@bytes)) do |gz|
        Gem::Package::TarReader.new(gz) { |tar| tar.each(&block) }
        # Reviewed bytes must equal extracted bytes: a concatenated gzip could
        # hide extra tar records in a second member that gunzip would extract
        # but this reader never saw. Drain boundedly and refuse leftovers.
        drained = 0
        while (chunk = gz.read(16 * 1024))
          drained += chunk.bytesize
          if drained > MAX_TRAILING_PADDING || chunk.delete("\0").present?
            raise InvalidTarball, "trailing data after the tar archive"
          end
        end
        raise InvalidTarball, "trailing data after the gzip stream" if gz.unused.present?
      end
    end

    # Normalize to canonical root-relative paths — "./x", "././x", and "a//b"
    # must collapse to the same path extraction would produce, or duplicate
    # detection can be sidestepped. Escapes are refused outright.
    def clean_path(raw)
      raise InvalidTarball, "illegal path in tarball: #{raw.inspect}" if raw.include?("\0") || raw.start_with?("/")
      # Names must be valid UTF-8 with no control characters — anything else
      # would poison fingerprint/scan JSON persistence downstream (and is a
      # smuggling vector in listings)
      utf8 = raw.dup.force_encoding(Encoding::UTF_8)
      unless utf8.valid_encoding? && !utf8.match?(/[\x00-\x1f\x7f]/)
        raise InvalidTarball, "tarball path is not clean UTF-8: #{raw.inspect}"
      end
      segments = raw.split("/").reject { |segment| segment == "." || segment.empty? }
      raise InvalidTarball, "illegal path in tarball: #{raw.inspect}" if segments.empty? || segments.include?("..")
      segments.join("/")
    end

    def parse_manifest(json)
      raise InvalidTarball, "#{MANIFEST_NAME} exceeds 64KB" if json.bytesize > 64.kilobytes
      parsed = JSON.parse(json)
      raise InvalidTarball, "#{MANIFEST_NAME} must be a JSON object" unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError => e
      raise InvalidTarball, "#{MANIFEST_NAME} is not valid JSON: #{e.message}"
    end
  end
end
