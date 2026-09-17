module Registry
  # Seeds plugins from the omarchyplugins.com catalog: each entry becomes an
  # UNCLAIMED publisher + a snapshot of the listed repo pushed through the full
  # review pipeline like any publish. Claiming a seeded namespace requires
  # one-time proof of control of the source repo (Registry::RepoProof).
  #
  # Entry shape: { "publisher" => "ryanrhughes", "name" => "weather",
  #   "summary" => "...", "repository" => "https://github.com/..." }
  class SeedCatalog
    # A reserved internal address, never published as a contact — the public
    # contact registry@omarchy.org must not double as the privileged principal.
    SYSTEM_EMAIL = "seed-system@plugins.omarchy.org".freeze

    # The system identity is an explicit flag, permanently suspended — it
    # exists only as a provenance marker for seeded versions and can never
    # sign in. If the reserved address was somehow registered interactively,
    # seeding REFUSES rather than conscripting a real account.
    def self.system_user
      user = User.find_or_create_by!(email_address: SYSTEM_EMAIL) do |u|
        u.name = "Omarchy Registry"
        u.system = true
        u.suspended_at = Time.current
      end
      unless user.system?
        raise "#{SYSTEM_EMAIL} exists as a non-system account — resolve manually before seeding"
      end
      user
    end

    def self.import(entries, snapshotter: RepoSnapshot.method(:tarball_for))
      entries.map do |entry|
        import_entry(entry, snapshotter:)
      end
    end

    def self.import_entry(entry, snapshotter:)
      # Publisher names persist lowercased — the same form the comparison uses
      publisher_name = entry.fetch("publisher").to_s.downcase
      # The claim-proof target must belong to the seeded namespace: the repo
      # owner segment has to match the publisher, or a mismatched catalog row
      # would make one person's namespace claimable through another's repo.
      owner = entry["repository"].to_s[%r{\Ahttps://[^/]+/([^/]+)/}, 1].to_s.downcase
      unless owner == publisher_name
        return { entry:, status: "failed", reason: "repository owner #{owner.inspect} does not match publisher" }
      end
      # Every accepted seed URL must be claimable later — a forge the claim
      # flow can't verify would strand the namespace unclaimed forever.
      if RepoProof.raw_claim_url(entry["repository"]).nil?
        return { entry:, status: "failed", reason: "unsupported forge for claim-proof (supported: github.com, codeberg.org, gitlab.com flat owner/repo)" }
      end

      publisher = Publisher.find_or_create_by!(name: publisher_name) do |p|
        p.kind = :personal
        p.claimed = false
        p.seed_source_url = entry["repository"]
      end
      # Never seed into a namespace someone already owns — a squatter who
      # claimed the name first must not receive the legitimate artifact under
      # their identity. Authors with several repos are fine: the publisher's
      # seed_source_url (their first listed repo) is only the claim-proof
      # target; each plugin keeps its own repository in its manifest.
      if publisher.claimed?
        return { entry:, status: "skipped", reason: "namespace already claimed" }
      end
      # ONE forge identity per seeded namespace: the same username on GitHub
      # and Codeberg is two unrelated people — proving one repo must never
      # grant plugins seeded from the other forge.
      if publisher.seed_source_url.present? &&
          URI(publisher.seed_source_url).host != URI(entry["repository"].to_s).host
        return { entry:, status: "failed",
                 reason: "conflicting forge identity: namespace already seeded from #{URI(publisher.seed_source_url).host}" }
      end
      return { entry:, status: "skipped", reason: "already published" } if
        publisher.plugins.find_by(name: entry.fetch("name"))&.versions&.exists?

      # Legacy-marketplace entries pin the exact commit the old marketplace
      # security-reviewed (`commit`) — never mutable HEAD — and carry the
      # original listing metadata for normalization and backdating.
      commit = entry["commit"].presence
      bytes = if commit && (snapshotter.arity < 0 || snapshotter.arity >= 2)
        snapshotter.call(entry.fetch("repository"), commit)
      else
        snapshotter.call(entry.fetch("repository"))
      end
      normalized = SeedNormalizer.normalize(bytes,
        publisher_name: publisher.name, plugin_name: entry.fetch("name"),
        category: entry["category"], tags: entry["tags"])
      version = PublishVersion.new(
        user: system_user, publisher:, plugin_name: entry.fetch("name"),
        tarball_bytes: normalized.bytes, system_seed: true,
        seed_provenance: seed_provenance(entry, commit:, legacy_id: normalized.legacy_id)
      ).call
      backdate!(version, entry["listed_at"])
      AuditEvent.record!(action: "plugin.seed", subject: version.plugin, public: true,
        metadata: { plugin: version.plugin.full_name, source: entry["repository"],
                    commit: commit, legacy_id: normalized.legacy_id }.compact)
      { entry:, status: "submitted", version: version.version }
    rescue ActiveRecord::RecordInvalid => e
      # A reserved/confusable publisher name fails ITS entry, not the batch
      { entry:, status: "failed", reason: e.message }
    rescue PublishVersion::PublishError, RepoSnapshot::SnapshotError, SeedNormalizer::NormalizeError => e
      # A legacy plugin whose snapshot fails validation must remain VISIBLE and
      # uninstallable, not silently vanish from the directory it came from.
      placeholder_plugin(entry, e.message)
      { entry:, status: "failed", reason: e.message }
    rescue KeyError => e
      { entry:, status: "failed", reason: e.message }
    end

    # Lineage recorded on the version: the reviewed source commit (rendered as
    # provenance on the plugin page) and the legacy identity the Omarchy client
    # needs to migrate old installs onto the registry track.
    def self.seed_provenance(entry, commit:, legacy_id:)
      owner_repo = entry["repository"].to_s[%r{\Ahttps://github\.com/([^/]+/[^/]+?)(?:\.git)?\z}, 1]
      legacy = { "id" => legacy_id, "listed_at" => entry["listed_at"].presence,
                 # Exact-commit passing evidence from the legacy marketplace —
                 # Advisory provenance for humans, never a review exemption.
                 "verified" => entry["verified"] == true || nil,
                 "verification" => entry["verification_method"].presence }.compact
      { "source" => "legacy-marketplace",
        "repository" => owner_repo,
        "sha" => commit,
        "legacy" => legacy.presence }.compact
    end

    # Imported plugins keep their original marketplace dates — 1,300+ seeds
    # stamped "now" would bury the newest/recent surfaces for weeks and wreck
    # publish-date analytics. published_at is backdated by ReleaseVersion
    # (from provenance) when the version clears review.
    def self.backdate!(version, listed_at)
      timestamp = Time.zone.parse(listed_at.to_s) rescue nil
      return if timestamp.nil?
      version.update_columns(created_at: timestamp)
      plugin = version.plugin
      plugin.update_columns(created_at: timestamp) if timestamp < plugin.created_at
    end

    def self.placeholder_plugin(entry, reason)
      publisher = Publisher.find_by(name: entry["publisher"].to_s.downcase)
      return if publisher.nil? || publisher.claimed?
      plugin = publisher.plugins.find_or_create_by!(name: entry["name"]) do |p|
        p.summary = entry["summary"]
        p.state = :quarantined
        p.allow_reserved = true
      end
      AuditEvent.record!(action: "plugin.seed_failed", subject: plugin, public: true,
        metadata: { plugin: plugin.full_name, source: entry["repository"], reason: reason.first(300) })
    rescue ActiveRecord::RecordInvalid
      nil
    end
  end
end
