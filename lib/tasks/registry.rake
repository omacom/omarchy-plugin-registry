namespace :registry do
  desc "Submit three labeled demo plugins through normal review (requires an existing admin email)"
  task :seed_demo, [ :email ] => :environment do |_task, args|
    admin = User.find_by(email_address: args[:email].to_s.strip.downcase)
    Registry::DemoCatalog.import(admin:).each do |version|
      puts "#{version.plugin.full_name}@#{version.version}: #{version.state} (admin review: /admin/versions/#{version.id})"
    end
    puts "Jobs run the scanner and AI reviewer. Approve clean first releases in /admin after enrolling a second factor."
  end

  desc "Grant admin to an account (the supported bootstrap for a fresh deployment)"
  task :grant_admin, [ :email ] => :environment do |_t, args|
    abort "usage: rails registry:grant_admin[you@example.com]" if args[:email].blank?
    user = User.find_or_create_by!(email_address: args[:email].strip.downcase)
    user.update!(admin: true)
    # Not public: the transparency log must not disclose admin login emails
    AuditEvent.record!(action: "user.grant_admin", subject: user)
    puts "#{user.email_address} is an admin. They must sign in and enroll a second factor before admin actions work."
  end

  desc "Seed plugins from a catalog JSON file (array of {publisher, name, summary, repository})"
  task :seed_catalog, [ :path ] => :environment do |_t, args|
    abort "usage: rails registry:seed_catalog[path/to/catalog.json]" if args[:path].blank?
    entries = JSON.parse(File.read(args[:path]))
    results = Registry::SeedCatalog.import(entries)
    results.each do |result|
      entry = result[:entry]
      puts "#{entry['publisher']}/#{entry['name']}: #{result[:status]}#{" — #{result[:reason]}" if result[:reason]}"
    end
    puts "Run pending review jobs (bin/jobs) or rails registry:process_reviews to complete the pipeline."
  end

  desc <<~DESC
    Transform the legacy marketplace's built catalog (site/catalog.json from
    HANCORE-linux/omarchy-plugin-marketplace) into seed entries + a dry-run
    report. Writes <out_dir>/entries.json (feed to registry:seed_catalog) and
    <out_dir>/report.json. Optional limit caps entries for a test batch.
  DESC
  task :transform_legacy_catalog, [ :catalog_path, :out_dir, :limit ] => :environment do |_t, args|
    abort "usage: rails registry:transform_legacy_catalog[catalog.json,out_dir,limit]" if args[:catalog_path].blank? || args[:out_dir].blank?
    catalog = JSON.parse(File.read(args[:catalog_path]))

    # Legacy display categories → registry taxonomy slugs. The four retired
    # legacy categories fold into their nearest current slug.
    category_map = {
      "appearance" => "appearance", "desktop" => "desktop", "developer tools" => "developer-tools",
      "hardware" => "hardware", "productivity" => "productivity", "system" => "system",
      "widgets" => "widgets", "other" => "other",
      "bar widgets" => "widgets", "services" => "system", "overlays" => "widgets", "panels" => "widgets"
    }

    entries, skipped, renamed = [], [], []
    names_seen = Hash.new { |h, k| h[k] = {} } # publisher => normalized name => plugin name

    catalog.fetch("plugins").each do |plugin|
      repo = plugin["repo"].to_s
      skip = lambda { |reason| skipped << { "id" => plugin["id"], "repo" => repo, "reason" => reason } }

      next skip.call("built-in (ships with Omarchy)") if plugin["sourceType"] != "community"
      next skip.call("shell suite — not an installable plugin") if plugin["repositoryLayout"] == "suite"
      # Monorepo/suite manifests live in subdirectories; the seed pipeline
      # expects a root manifest. Handful of sources — import by hand later.
      next skip.call("manifest not at repository root (#{plugin['manifestPath'] || 'missing'})") if plugin["manifestPath"] != "manifest.json"
      next skip.call("no validated commit recorded") if plugin["listingValidatedCommit"].to_s.length != 40

      owner, repo_name = repo[%r{\Ahttps://github\.com/([^/]+/[^/]+?)(?:\.git)?/?\z}, 1].to_s.split("/")
      next skip.call("unparseable github repo URL") if owner.blank? || repo_name.blank?

      publisher = owner.downcase
      name = repo_name.downcase.gsub(/[^a-z0-9_-]+/, "-").squeeze("-").sub(/\A[-_]+/, "").sub(/[-_]+\z/, "").first(NameRules::MAX_LENGTH)
      next skip.call("repo name sanitizes to nothing") if name.blank?
      renamed << { "repo" => repo, "name" => name } if name != repo_name

      # One plugin per (publisher, name) INCLUDING confusable folding — a
      # second repo landing on the same name would seed into the first
      # plugin's identity. Flag for a manual decision instead.
      folded = NameRules.normalize(name)
      if (existing = names_seen[publisher][folded])
        next skip.call("name collides with #{publisher}/#{existing} after normalization")
      end
      names_seen[publisher][folded] = name

      entries << {
        "publisher" => publisher,
        "name" => name,
        "summary" => plugin["description"].to_s.strip,
        "repository" => "https://github.com/#{owner}/#{repo_name}",
        "commit" => plugin["listingValidatedCommit"],
        "listed_at" => plugin["listedAt"].presence || plugin["addedAt"].presence,
        "category" => category_map[plugin["category"].to_s.downcase],
        "tags" => Array(plugin["tags"]).map { |t| t.to_s.downcase },
        # Exact-commit legacy verification: "verified" on the legacy site
        # means the RECORDED snapshot has passing baseline evidence or a
        # maintainer attestation, and that snapshot is the commit we import.
        "verified" => plugin["verificationStatus"] == "verified" &&
          (plugin["verificationCommit"].blank? || plugin["verificationCommit"] == plugin["listingValidatedCommit"]),
        "verification_method" => plugin["verificationMethod"].presence,
        # Report-only context, ignored by the importer:
        "legacy_catalog_id" => plugin["id"],
        "manual_setup" => plugin["installAvailable"] == false
      }
    end

    entries = entries.first(args[:limit].to_i) if args[:limit].present?

    FileUtils.mkdir_p(args[:out_dir])
    File.write(File.join(args[:out_dir], "entries.json"), JSON.pretty_generate(entries))
    report = {
      "generated_from" => args[:catalog_path],
      "entries" => entries.length,
      "skipped" => skipped.length,
      "renamed" => renamed.length,
      "manual_setup" => entries.count { |e| e["manual_setup"] },
      "reserved_names_grandfathered" => entries.count { |e| NameRules.reserved?(e["name"]) },
      "missing_listed_at" => entries.count { |e| e["listed_at"].blank? },
      "unmapped_category" => entries.count { |e| e["category"].blank? },
      "skipped_detail" => skipped,
      "renamed_detail" => renamed
    }
    File.write(File.join(args[:out_dir], "report.json"), JSON.pretty_generate(report))
    puts report.except("skipped_detail", "renamed_detail").map { |k, v| "#{k}: #{v}" }.join("\n")
    puts "Wrote #{File.join(args[:out_dir], 'entries.json')} and report.json"
  end

  desc "Run any pending review jobs inline (useful right after seeding)"
  task process_reviews: :environment do
    PluginVersion.processing.find_each do |version|
      Registry::ReviewJob.perform_now(version)
      puts "#{version.plugin.full_name}@#{version.version}: #{version.reload.state}"
    end
    DataPlane::RegenerateJob.perform_later
    puts "Data-plane regeneration queued."
  end

  desc "Import page-view counts from edge analytics (JSONL: {publisher,name,count})"
  task :import_view_counts, [ :path ] => :environment do |_t, args|
    abort "usage: rails registry:import_view_counts[views.jsonl]" if args[:path].blank?
    File.foreach(args[:path]) do |line|
      entry = JSON.parse(line) rescue next
      plugin = Plugin.joins(:publisher).find_by(publishers: { name: entry["publisher"] }, name: entry["name"])
      plugin&.update_columns(views_count: plugin.views_count + entry["count"].to_i)
    end
    puts "View counts imported."
  end

  desc "Import + enforce a signed revocations.json from ANY surviving copy (CDN cache, object storage, a client mirror) after a restore"
  task :import_revocations, [ :path ] => :environment do |_t, args|
    abort "usage: rails registry:import_revocations[revocations.json] (with its .sig alongside)" if args[:path].blank?
    content = File.read(args[:path])
    signature_path = "#{args[:path]}.sig"
    abort "#{signature_path} missing — only SIGNED kill lists can be imported" unless File.exist?(signature_path)
    abort "signature verification failed" unless DataPlane::Signer.verify_any?(content, File.read(signature_path))

    # The SAME generator instance runs the full regeneration so orphan entries
    # (revocations whose plugin the restored DB predates) land in the freshly
    # written kill list even when the on-disk data plane was lost too.
    # The authoritative pair becomes the on-disk kill list FIRST, so the
    # regeneration's witness check and reconciliation both see it
    FileUtils.mkdir_p(DataPlane.root)
    FileUtils.cp(args[:path], DataPlane.root.join("revocations.json"))
    FileUtils.cp(signature_path, DataPlane.root.join("revocations.json.sig"))
    generator = DataPlane::Regenerate.new
    generator.import_revocation_entries(JSON.parse(content).fetch("revocations", []))
    DataPlane::Regenerate.all(generator)
    puts "Revocations imported, enforced, and written; data plane regenerated at #{DataPlane.root}."
  end

  desc "Regenerate the entire static data plane (queued — respects the single-regenerator lock)"
  task regenerate: :environment do
    DataPlane::RegenerateJob.perform_later
    puts "Regeneration queued (bin/jobs must be running); output: #{DataPlane.root}"
  end

  desc "Rewrite encrypted secrets under the CURRENT key (run after rotating SECRET_KEY_BASE, before dropping OLD_SECRET_KEY_BASE)"
  task reencrypt_secrets: :environment do
    count = 0
    User.where.not(otp_secret: nil).find_each do |user|
      # Rails' official re-encryption path: decrypts (previous keys allowed),
      # re-encrypts under the current primary
      user.encrypt
      count += 1
    end
    puts "Re-encrypted #{count} TOTP seeds under the current primary key."
  end

  desc <<~DESC
    Import download counts from CDN log aggregation (the production counting
    path). Input: JSONL, one {"publisher","name","version","count","date"} per
    line — produce it from your CDN's logs for GET /dl/... with status 200.
  DESC
  task :import_download_counts, [ :path ] => :environment do |_t, args|
    abort "usage: rails registry:import_download_counts[counts.jsonl]" if args[:path].blank?
    imported = skipped = 0
    File.foreach(args[:path]) do |line|
      entry = JSON.parse(line) rescue next
      version = PluginVersion.joins(plugin: :publisher).find_by(
        publishers: { name: entry["publisher"] }, plugins: { name: entry["name"] },
        version: entry["version"])
      next skipped += 1 if version.nil? || entry["count"].to_i <= 0

      date = Date.parse(entry["date"]) rescue Date.current
      DailyDownload.upsert(
        { plugin_version_id: version.id, date: date, count: entry["count"].to_i },
        unique_by: [ :plugin_version_id, :date ],
        on_duplicate: Arel.sql("count = excluded.count"))
      imported += 1
    end
    # Refresh the cached rollups from the ledger
    PluginVersion.find_each do |version|
      version.update_columns(downloads_count: version.daily_downloads.sum(:count))
    end
    Plugin.find_each do |plugin|
      plugin.update_columns(downloads_count: plugin.versions.sum(:downloads_count))
    end
    DataPlane::RegenerateJob.perform_later
    puts "Imported #{imported} rows (#{skipped} skipped); rollups refreshed, regeneration queued."
  end
end
