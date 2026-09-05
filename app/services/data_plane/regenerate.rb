module DataPlane
  # Regenerates the static index. Cheap at Omarchy's scale — the whole index
  # can be rebuilt on every publish (the crates.io degenerate case).
  class Regenerate
    # Raised when an on-disk kill list exists but can't be trusted — the run
    # must die before writing anything, or a restored pre-revocation database
    # would sign a fresh (empty) kill list over it.
    class CorruptKillListError < StandardError; end

    # Raised when the surviving signed plugin index lists a version the
    # database doesn't know — the database was restored from a pre-publish
    # backup, and signing a higher-generation index without that version
    # would make clients accept the silent drop.
    class IndexContinuityError < StandardError; end

    # Raised when a published/yanked version's frozen bytes are missing or
    # corrupt and Active Storage can't supply verified replacement bytes —
    # regeneration aborts BEFORE writing anything, preserving the prior
    # signed index byte-for-byte.
    class ArtifactIntegrityError < StandardError; end

    # Raised when the external witness proves the whole volume (database AND
    # data plane) was restored from before the last signed kill list — the
    # wall-clock generation anchor would otherwise happily sign a NEWER empty
    # kill list and defeat client rollback detection.
    class StaleRestoreError < StandardError; end

    # A per-plugin trigger still rebuilds everything (cheap at this scale) —
    # writing the one index first and then rewriting it under a second
    # generation would just churn two generations for one publish.
    def self.plugin(_plugin)
      all
    end

    # An externally supplied generator carries pre-imported orphan revocations
    # (registry:import_revocations) into the SAME run that writes the kill list.
    # A cross-process file lock serializes EVERY caller — the recurring job,
    # publish-triggered runs, and operator rake tasks — so two runs can never
    # interleave the deterministic .staged promotion paths.
    def self.all(generator = new)
      FileUtils.mkdir_p(DataPlane.root)
      File.open(DataPlane.root.join(".regenerate.lock"), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        # The external witness (a file OUTSIDE the app volume) gates
        # regeneration after a full-volume restore — see check_restore_witness!
        generator.check_restore_witness!
        # Reconciliation FIRST: revocations recorded on the surviving data
        # plane are re-learned and ENFORCED before anything is signed, so
        # every file written below reflects post-takedown state.
        generator.reconcile_disk_revocations!
        # The kill list signs IMMEDIATELY after reconciliation — emergency
        # containment must never be held hostage by an unrelated plugin's
        # corrupt artifact failing the preflight below.
        generator.write_config
        generator.write_revocations
        generator.record_witness!
        # Artifact verification is scoped PER PLUGIN: a corrupt artifact
        # freezes only its own plugin's index (prior signed pair preserved
        # byte-for-byte) while every healthy plugin's takedowns, yanks, and
        # releases still reach their signed indexes. The aggregate failure
        # still raises at the end so the run is operator-visible.
        artifact_failures = []
        failed_plugin_ids = []
        Plugin.find_each do |p|
          generator.ensure_artifacts!(p)
          generator.write_plugin_index(p)
        rescue ArtifactIntegrityError => e
          artifact_failures << e.message
          failed_plugin_ids << p.id
          Rails.logger.error("[DataPlane] #{e.message} — this plugin's index left untouched")
        end
        generator.warn_orphan_indexes!
        generator.write_all_listing(failed_plugin_ids: failed_plugin_ids)
        generator.write_legacy_map
        raise ArtifactIntegrityError, artifact_failures.join("; ") if artifact_failures.any?
      end
    end

    # Full regeneration must be able to rebuild the ENTIRE data plane from the
    # database, and every artifact a signed index will promise is CHECKSUMMED
    # first: a frozen file that rotted re-restores from verified Active
    # Storage bytes, and a version with no valid bytes anywhere aborts the run
    # (fail closed — the prior signed index survives byte-for-byte).
    def ensure_artifacts!(plugin)
      plugin.versions.where(state: [ :published, :yanked ]).find_each do |version|
        path = DataPlane.root.join(version.tarball_path)
        next if path.exist? && Digest::SHA256.file(path).hexdigest == version.sha256
        unless version.tarball.attached?
          raise ArtifactIntegrityError,
            "#{version.tarball_path} is missing or corrupt with no stored blob to restore from — " \
            "recover the artifact (or take the version down) before regenerating"
        end
        bytes = version.tarball.download
        unless Digest::SHA256.hexdigest(bytes) == version.sha256
          raise ArtifactIntegrityError,
            "stored blob for #{version.tarball_path} fails its checksum — nothing valid to serve; " \
            "recover the artifact (or take the version down) before regenerating"
        end
        DataPlane.atomic_write(version.tarball_path, bytes)
      end
    end

    # A restore of BOTH the database and the data plane is locally
    # undetectable — every on-volume artifact is consistent, just old. The
    # witness file (REGISTRY_WITNESS_PATH, on separate storage) records the
    # last signed kill-list generation; a data plane holding an OLDER
    # generation than the witness proves a restore, and regeneration refuses
    # to sign a newer-generation kill list over it until the authoritative
    # copy is imported (or the operator explicitly acks with
    # REGISTRY_RESTORE_ACK=1). Unset witness = documented residual risk.
    def check_restore_witness!
      witness_path = ENV["REGISTRY_WITNESS_PATH"].presence
      return unless witness_path
      return if ENV["REGISTRY_RESTORE_ACK"] == "1"
      witness = begin
        JSON.parse(File.read(witness_path))
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end
      return unless witness
      disk = DataPlane.root.join("revocations.json")
      disk_generation = begin
        disk.exist? ? JSON.parse(disk.read)["generation"].to_i : 0
      rescue JSON::ParserError
        0
      end
      if witness["generation"].to_i > disk_generation
        raise StaleRestoreError,
          "external witness records kill-list generation #{witness['generation']} but the data plane holds " \
          "#{disk_generation} — the volume was restored from an older backup. Import the latest authoritative " \
          "revocations.json (bin/rails 'registry:import_revocations[path]') before regenerating, or set " \
          "REGISTRY_RESTORE_ACK=1 for one run if this older state is deliberately authoritative."
      end
    end

    def record_witness!
      witness_path = ENV["REGISTRY_WITNESS_PATH"].presence
      return unless witness_path
      content = DataPlane.root.join("revocations.json").read
      payload = JSON.generate({
        "generation" => JSON.parse(content)["generation"],
        "revocations_sha256" => Digest::SHA256.hexdigest(content),
        "recorded_at" => Time.current.utc.iso8601
      })
      temp = "#{witness_path}.tmp-#{Process.pid}"
      File.write(temp, payload)
      File.rename(temp, witness_path)
    end

    # A restored database may predate ENTIRE plugin rows. Their surviving
    # signed indexes are deliberately left untouched (clients keep verifying
    # them until freshness expires) and flagged every run so the loss is
    # visible to an operator before expiry hides it.
    def warn_orphan_indexes!
      index_root = DataPlane.root.join("index")
      return unless index_root.exist?
      known = Plugin.includes(:publisher).map { |p| "#{p.publisher.name}/#{p.name}.json" }.to_set
      index_root.glob("*/*.json").each do |file|
        relative = file.relative_path_from(index_root).to_s
        next if known.include?(relative)
        Rails.logger.warn("[DataPlane] orphan signed index #{relative} — no matching plugin row " \
          "(database restored from an older backup?); left untouched, restore the row or remove the pair")
      end
    end

    # Freshness horizons: signed files carry generated_at/expires_at so a
    # stale or rolled-back CDN/object-store copy stops verifying. The kill
    # list regenerates every 10 minutes and expires fastest — clients fail
    # CLOSED on an expired revocation list.
    REVOCATIONS_TTL = 24.hours
    INDEX_TTL = 7.days

    # One strictly-increasing generation per regeneration run: clients order
    # signed files by this integer. Anchored to wall-clock milliseconds so a
    # database restore can't re-issue generations clients already saw, while
    # the counter guarantees strict increase even within one millisecond.
    def generation
      @generation ||= RegistryCounter.next!("data_plane_generation",
        floor: (Time.current.to_f * 1000).to_i)
    end

    def freshness(ttl)
      { "generation" => generation,
        "generated_at" => Time.current.utc.iso8601,
        "expires_at" => ttl.from_now.utc.iso8601 }
    end

    def write_config
      # The public key is served unsigned (trust root — clients pin it);
      # everything else carries a detached .sig made with this key. A CHANGED
      # key aborts regeneration outright: an accidental seed swap must never
      # silently replace the trust root and strand every pinned client.
      key_path = DataPlane.root.join("signing-key.pub")
      FileUtils.mkdir_p(DataPlane.root)
      if key_path.exist? && key_path.read != Signer.public_key_base64
        unless ENV["REGISTRY_ALLOW_KEY_ROTATION"] == "1" &&
            ENV["REGISTRY_PREVIOUS_SIGNING_PUBKEY"].to_s.strip == key_path.read.strip &&
            ENV["REGISTRY_ROTATION_ACK"] == "clients-must-repin"
          raise "signing key changed since the data plane was written — refusing to replace the trust root. " \
                "Rotation is a COORDINATED INCOMPATIBLE EVENT: deployed clients pin one key and fail closed " \
                "until they re-pin. It requires REGISTRY_ALLOW_KEY_ROTATION=1, " \
                "REGISTRY_PREVIOUS_SIGNING_PUBKEY set to the current on-disk trust root, AND " \
                "REGISTRY_ROTATION_ACK=clients-must-repin acknowledging the client-side impact"
        end
      end
      # Atomic, and only when it actually changed — a recurring rewrite must
      # never risk a truncated trust root
      unless key_path.exist? && key_path.read == Signer.public_key_base64
        DataPlane.atomic_write("signing-key.pub", Signer.public_key_base64)
      end

      DataPlane.write("config.json", JSON.pretty_generate({
        "packageTypes" => Plugin::PACKAGE_TYPES,
        "dl" => "#{DataPlane.base_url}/dl/{publisher}/{name}/{name}-{version}.tar.gz",
        "index" => "#{DataPlane.base_url}/index/{publisher}/{name}.json",
        "revocations" => "#{DataPlane.base_url}/revocations.json",
        "legacy_map" => "#{DataPlane.base_url}/legacy-map.json",
        "signing_key" => "#{DataPlane.base_url}/signing-key.pub",
        "api" => DataPlane.base_url
      }.merge(freshness(INDEX_TTL))))
    end

    # One JSON line per version, append-only in spirit: every version ever
    # created appears; only published/yanked are useful to clients, and yanked
    # versions stay listed (with the flag) for reproducibility. The first line
    # is a meta record carrying the freshness horizon.
    def write_plugin_index(plugin)
      relative = "index/#{plugin.publisher.name}/#{plugin.name}.json"
      verify_index_continuity!(plugin, relative)
      lines = [ JSON.generate({ "meta" => true }.merge(freshness(INDEX_TTL))) ]
      plugin.versions.where(state: [ :published, :yanked ]).order(:version_sort_key).each do |v|
        # ensure_artifacts! verified every promised artifact before any write
        lines << JSON.generate(version_entry(v))
      end
      DataPlane.write(relative, lines.join("\n") + "\n")
    end

    # The index is append-only: a version once promised by a signed index may
    # change state but its ROW never leaves the database. If the surviving
    # signed index lists versions the database doesn't know, the database
    # predates them (restored from an old backup) — fail closed for operator
    # recovery instead of signing a higher-generation index that drops them.
    def verify_index_continuity!(plugin, relative)
      DataPlane.heal_interrupted_write!(relative)
      path = DataPlane.root.join(relative)
      signature = DataPlane.root.join("#{relative}.sig")
      return unless path.exist? || signature.exist?
      raise IndexContinuityError, "#{relative} exists without its .sig sibling" unless signature.exist?
      raise IndexContinuityError, "#{relative}.sig exists without its index" unless path.exist?
      content = path.read
      # Continuity holds THROUGH a rotation — old-key files verify via the
      # explicitly supplied previous public key, never an unverified skip
      unless Signer.verify_any?(content, signature.read)
        raise IndexContinuityError, "#{relative} signature does not verify " \
          "(mid-rotation, supply REGISTRY_PREVIOUS_SIGNING_PUBKEY)"
      end
      rows = plugin.versions.index_by(&:version)
      content.each_line do |line|
        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError => e
          raise IndexContinuityError, "#{relative} is signed but malformed: #{e.message}"
        end
        next if entry["meta"]
        row = rows[entry["vers"]]
        if row.nil?
          raise IndexContinuityError,
            "signed index for #{plugin.full_name} lists #{entry["vers"]} but the database doesn't know it — " \
            "restore a database that includes it (or deliberately remove the index pair) before regenerating"
        end
        # Signed state is MONOTONIC across restores: a yank never reverts, and
        # a promised version never slides back to pre-publication limbo. Only
        # deliberate post-publication takedowns (quarantine/reject of a
        # once-published version) may drop an entry from the index.
        if entry["yanked"] && row.published?
          row.yank!(reason: "yank restored from signed index", actor: Registry::SeedCatalog.system_user)
        elsif !row.published? && !row.yanked? && row.published_at.blank?
          raise IndexContinuityError,
            "signed index for #{plugin.full_name} promises #{entry["vers"]} but the database has it #{row.state} " \
            "and never published — the database predates its publication; restore a newer backup"
        end
      end
    end

    # A plugin whose index write was frozen by an artifact failure must not
    # have all.json advertise NEWER database state than its signed index —
    # its prior aggregate entry is carried forward verbatim (or omitted when
    # no trustworthy prior listing exists).
    def write_all_listing(failed_plugin_ids: [])
      prior = prior_all_entries if failed_plugin_ids.any?
      plugins = Plugin.listed.includes(:publisher).filter_map do |plugin|
        if failed_plugin_ids.include?(plugin.id)
          next prior&.dig("#{plugin.publisher.name}.#{plugin.name}")
        end
        next unless plugin.latest_version
        {
          "publisher" => plugin.publisher.name,
          "name" => plugin.name,
          "id" => plugin.manifest_id,
          "packageType" => plugin.package_type,
          "summary" => plugin.summary,
          "kinds" => plugin.kinds,
          "category" => plugin.category,
          "tags" => plugin.tags,
          "latest" => plugin.latest_version,
          "downloads" => plugin.downloads_count
        }
      end
      # Old clients read only plugins; themes must never appear as executable
      # plugin candidates. Both lists share one signature and generation.
      themes, plugins = plugins.partition { |entry| entry["packageType"] == "theme" }
      DataPlane.write("all.json", JSON.generate({ "plugins" => plugins, "themes" => themes }.merge(freshness(INDEX_TTL))))
    end

    # Migration map for installs made through the legacy marketplace: the
    # Omarchy client matches a receipt-less installed folder by BOTH its
    # legacy manifest id AND its source repo (legacy ids were never centrally
    # unique on disk — id alone could adopt the wrong folder), then converts
    # it to the registry-hosted plugin. Only currently installable plugins
    # appear; a delisted import must not invite a conversion to nothing.
    def write_legacy_map
      mappings = Plugin.listed.where.not(latest_version: nil).includes(:publisher, :versions).filter_map do |plugin|
        seeded = plugin.versions.detect { |v| v.legacy_id.present? }
        next unless seeded
        { "legacyId" => seeded.legacy_id,
          "source" => "https://github.com/#{seeded.provenance["repository"]}",
          "publisher" => plugin.publisher.name,
          "name" => plugin.name }
      end
      DataPlane.write("legacy-map.json", JSON.pretty_generate(
        { "schemaVersion" => 1, "mappings" => mappings }.merge(freshness(INDEX_TTL))))
    end

    # Previous all.json entries keyed by full name — only if the pair still
    # verifies (a tampered aggregate contributes nothing).
    def prior_all_entries
      DataPlane.heal_interrupted_write!("all.json")
      path = DataPlane.root.join("all.json")
      signature = DataPlane.root.join("all.json.sig")
      return nil unless path.exist? && signature.exist?
      content = path.read
      return nil unless Signer.verify_any?(content, signature.read)
      listing = JSON.parse(content)
      (listing.fetch("plugins", []) + listing.fetch("themes", [])).index_by { |e| "#{e['publisher']}.#{e['name']}" }
    rescue JSON::ParserError
      nil
    end

    # The kill list is append-critical: the union of database revocations and
    # any orphan entries preserved from the on-disk file (plugins the restored
    # database no longer knows still stay revoked — a signed revocation is
    # never erased just because a backup predates its plugin row).
    def write_revocations
      entries = Revocation.includes(plugin: :publisher).order(:created_at).map(&:as_kill_list_entry)
      known = entries.map { |e| [ e["plugin"], e["version"] ] }.to_set
      orphans = (@orphan_revocations || []).reject { |e| known.include?([ e["plugin"], e["version"] ]) }
      DataPlane.write("revocations.json", JSON.pretty_generate(
        { "schemaVersion" => 1, "revocations" => entries + orphans }.merge(freshness(REVOCATIONS_TTL))))
    end

    # A database restored from a pre-revocation backup re-learns every signed
    # on-disk revocation AND re-applies its effects: versions yank, whole-plugin
    # revocations security-hold, in-flight work stops, latest refreshes.
    def reconcile_disk_revocations!
      @orphan_revocations ||= []
      DataPlane.heal_interrupted_write!("revocations.json")
      path = DataPlane.root.join("revocations.json")
      signature = DataPlane.root.join("revocations.json.sig")
      return unless path.exist? || signature.exist?

      # FAIL CLOSED: an existing-but-unverifiable kill list (missing sibling,
      # bad signature, malformed JSON) must ABORT regeneration. Proceeding
      # would overwrite the client-visible mismatch with a freshly signed
      # kill list built from the (possibly pre-revocation) database — reviving
      # revoked artifacts. An operator must restore or explicitly remove the
      # pair before regeneration resumes.
      raise CorruptKillListError, "revocations.json exists without its .sig sibling" unless signature.exist?
      raise CorruptKillListError, "revocations.json.sig exists without revocations.json" unless path.exist?
      content = path.read
      # verify_any? keeps this FAIL-CLOSED through a rotation: the old kill
      # list verifies under REGISTRY_PREVIOUS_SIGNING_PUBKEY and imports
      # normally (orphans preserved) — there is no unverified bypass.
      unless Signer.verify_any?(content, signature.read)
        raise CorruptKillListError, "revocations.json signature does not verify " \
          "(mid-rotation, supply REGISTRY_PREVIOUS_SIGNING_PUBKEY so the old kill list can be verified)"
      end
      entries = begin
        JSON.parse(content).fetch("revocations", [])
      rescue JSON::ParserError => e
        raise CorruptKillListError, "revocations.json is signed but malformed: #{e.message}"
      end

      import_revocation_entries(entries)
    end

    # Idempotent, enforcement-first: every entry is re-ENFORCED on every run
    # (a crash between row creation and enforcement heals on the next pass),
    # and the row is created only after enforcement held. Shared with
    # registry:import_revocations for recovery from any surviving signed copy.
    def import_revocation_entries(entries)
      @orphan_revocations ||= []
      entries.each do |entry|
        publisher_name, plugin_name = entry["plugin"].to_s.split(".", 2)
        plugin = Plugin.joins(:publisher).find_by(publishers: { name: publisher_name }, name: plugin_name)
        if plugin.nil?
          # The restored DB predates this plugin — its revocation survives in
          # the kill list verbatim rather than being silently erased
          @orphan_revocations << entry.slice("plugin", "version", "reason", "revoked_at")
          next
        end
        reason = entry["reason"].presence || "restored from data plane"
        enforce_revocation!(plugin, entry["version"], reason)
        next if Revocation.exists?(plugin:, version: entry["version"])
        Revocation.create!(plugin:, version: entry["version"], reason:,
          created_by: Registry::SeedCatalog.system_user)
        AuditEvent.record!(action: "revocation.reimported", subject: plugin, public: true,
          metadata: { plugin: entry["plugin"], version: entry["version"] })
      end
    end

    def enforce_revocation!(plugin, version_string, reason)
      system_user = Registry::SeedCatalog.system_user
      if version_string.present?
        version = plugin.versions.find_by(version: version_string)
        return if version.nil? || version.yanked? || version.rejected? # already enforced
        if version.published?
          version.yank!(reason:, actor: system_user)
        else
          version.update!(state: :yanked, yanked_at: Time.current, yank_reason: reason)
        end
      else
        plugin.update!(state: :security_holding, latest_version: nil) unless plugin.security_holding?
        plugin.versions.published.find_each { |v| v.yank!(reason:, actor: system_user) }
        plugin.versions.where(state: [ :processing, :held, :quarantined ], published_at: nil)
          .update_all(state: PluginVersion.states[:rejected], review_notes: "revocation restored: #{reason}")
        plugin.versions.where(state: [ :processing, :held, :quarantined ]).where.not(published_at: nil)
          .update_all(state: PluginVersion.states[:yanked], yanked_at: Time.current, yank_reason: reason)
      end
      plugin.refresh_latest_version!
    end

    private

    def version_entry(version)
      {
        "id" => version.plugin.manifest_id,
        "packageType" => version.plugin.package_type,
        "vers" => version.version,
        "sha256" => version.sha256,
        "size" => version.size_bytes,
        "yanked" => version.yanked?,
        "license" => version.license,
        "minOmarchyVersion" => version.min_omarchy_version,
        "kinds" => version.manifest["kinds"],
        "caps" => version.capability_fingerprint
      }.compact
    end
  end
end
