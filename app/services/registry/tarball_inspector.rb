module Registry
  # Safely inspects an uploaded .tar.gz without trusting it: enforces size and
  # entry limits, rejects symlinks/hardlinks/devices, absolute paths, and path
  # traversal. Never extracts to disk — reads manifest and readme in memory.
  class TarballInspector
    class InvalidTarball < StandardError; end

    MAX_TARBALL_BYTES = 10.megabytes
    MAX_UNPACKED_BYTES = 50.megabytes
    MAX_ENTRIES = 2_000
    MANIFEST_NAME = "manifest.json"
    README_CANDIDATES = %w[README.md readme.md README Readme.md].freeze
    # Optional root preview image, first match wins in this order. Kept as full
    # bytes (the 512KB scan window would truncate any real screenshot).
    PREVIEW_CANDIDATES = %w[preview.png preview.jpg preview.jpeg preview.webp preview.gif].freeze

    # Per-file cap on content retained for scanning; larger files keep only
    # their first MAX_SCAN_BYTES (the scanner flags oversized/binary blobs anyway).
    MAX_SCAN_BYTES = 512.kilobytes

    attr_reader :manifest, :readme, :files, :contents, :digests, :truncated, :sha256, :size_bytes,
      :preview_name, :preview_bytes, :payload_markers

    def self.inspect_bytes(bytes)
      new(bytes).tap(&:inspect!)
    end

    def initialize(bytes)
      @bytes = bytes
    end

    def inspect!
      @size_bytes = @bytes.bytesize
      raise InvalidTarball, "tarball is empty" if @size_bytes.zero?
      raise InvalidTarball, "tarball exceeds #{MAX_TARBALL_BYTES / 1.megabyte}MB limit" if @size_bytes > MAX_TARBALL_BYTES

      @sha256 = Digest::SHA256.hexdigest(@bytes)
      @files = []
      @contents = {}
      @payload_markers = {}
      @digests = {} # full-content SHA-256 per file — diffing must never rely on the truncated scan window
      @truncated = []
      manifest_json = nil
      readme_content = nil
      previews = {}

      SafeTar.each_file(@bytes, max_entries: MAX_ENTRIES, max_unpacked_bytes: MAX_UNPACKED_BYTES) do |path, content|
        @files << path
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
        previews[path] = content if PREVIEW_CANDIDATES.include?(path)
      end

      raise InvalidTarball, "#{MANIFEST_NAME} missing at tarball root" if manifest_json.nil?
      @manifest = parse_manifest(manifest_json)
      @readme = readme_content&.valid_encoding? ? readme_content : nil
      # Only one preview ships per plugin — a second candidate name is an
      # ambiguity (which one did the author mean?), so refuse it outright.
      raise InvalidTarball, "multiple preview images (#{previews.keys.sort.join(', ')}) — ship exactly one" if previews.size > 1
      @preview_name, @preview_bytes = previews.first
      self
    rescue SafeTar::Invalid => e
      raise InvalidTarball, e.message
    end

    def include?(path) = files.include?(path)

    private

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
