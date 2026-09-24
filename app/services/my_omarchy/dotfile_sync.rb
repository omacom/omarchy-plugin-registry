module MyOmarchy
  # Ingests one pushed dotfile bundle. The archive is walked with the same
  # reader plugin tarballs go through (no symlinks, no escapes, no smuggled
  # bytes), the forbidden-path list is enforced server-side, and the listing
  # is derived from what was actually inside — never from what the client
  # claimed. Encrypted bundles can't be walked: they are stored opaque with
  # the client's declared listing, and the page says so.
  class DotfileSync
    class Rejected < StandardError
      attr_reader :status
      def initialize(message, status: :unprocessable_entity)
        super(message)
        @status = status
      end
    end

    AGE_HEADER = "age-encryption.org/v1\n".b

    def initialize(user:, bytes:, token: nil, device_name: nil, declared_manifest: nil)
      @user = user
      @bytes = bytes
      @token = token
      @device_name = ApiToken.sanitize_device_name(device_name)
      @declared = declared_manifest.is_a?(Hash) ? declared_manifest : {}
    end

    def call
      raise Rejected.new("bundle is empty") if @bytes.bytesize.zero?
      if @bytes.bytesize > DotfileBundle::MAX_ARCHIVE_BYTES
        raise Rejected.new("bundle exceeds #{DotfileBundle::MAX_ARCHIVE_BYTES / 1.megabyte}MB", status: :content_too_large)
      end

      encryption, manifest, file_count = inspect_bundle
      bundle = nil
      ApplicationRecord.transaction do
        bundle = @user.dotfile_bundles.create!(
          api_token: @token, device_name: @device_name,
          sha256: Digest::SHA256.hexdigest(@bytes), size_bytes: @bytes.bytesize,
          file_count: file_count, encryption: encryption, manifest: manifest)
        bundle.archive.attach(io: StringIO.new(@bytes), filename: "dotfiles-#{bundle.id}.tar.gz",
          content_type: "application/gzip")
        prune!
      end
      AuditEvent.record!(actor: @user, action: "dotfiles.push", subject: bundle,
        metadata: { device: @device_name, files: file_count, encryption: encryption })
      bundle
    end

    private

    def inspect_bundle
      return inspect_encrypted if @bytes.start_with?(AGE_HEADER)

      paths = []
      Registry::SafeTar.each_file(@bytes, max_entries: DotfileBundle::MAX_ENTRIES,
                                   max_unpacked_bytes: DotfileBundle::MAX_UNPACKED_BYTES) do |path, _content|
        raise Rejected.new("bundle contains a path that is never synced: #{path}") if DotfileBundle.forbidden_path?(path)
        paths << path
      end
      raise Rejected.new("bundle contains no files") if paths.empty?
      [ :plain, manifest_for(paths.sort), paths.size ]
    rescue Registry::SafeTar::Invalid => e
      raise Rejected.new(e.message)
    end

    # The server can't look inside; it stores what the client declared and
    # still refuses a listing that admits to carrying a forbidden path.
    def inspect_encrypted
      paths = Array(@declared["paths"]).grep(String).map { |p| p.delete_prefix("./") }
      forbidden = paths.find { |path| DotfileBundle.forbidden_path?(path) }
      raise Rejected.new("bundle declares a path that is never synced: #{forbidden}") if forbidden
      [ :age, manifest_for(paths.sort.uniq), paths.uniq.size ]
    end

    def manifest_for(paths)
      { "paths" => paths.first(DotfileBundle::MAX_ENTRIES),
        "omarchy_version" => @declared["omarchy_version"].to_s.first(64).presence,
        "hostname" => @device_name }.compact
    end

    # Storage is bounded per account: keep the newest KEEP_PER_USER snapshots
    # and purge the rest, bytes included.
    def prune!
      # to_a, not find_each: batching reorders by id ASC, which would turn
      # "everything past the newest N" into "everything past the OLDEST N"
      stale = @user.dotfile_bundles.newest_first.offset(DotfileBundle::KEEP_PER_USER).to_a
      stale.each do |bundle|
        bundle.archive.purge_later if bundle.archive.attached?
        bundle.destroy!
      end
    end
  end
end
