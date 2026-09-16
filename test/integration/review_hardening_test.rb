require "test_helper"

class ReviewHardeningTest < ActionDispatch::IntegrationTest
  setup do
    @dev = User.create!(email_address: "dev@example.com", name: "Dev", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @dev, role: :owner, founding: true)
  end

  teardown do
    Rails.application.config.x.ai_review_command = nil
    Rails.application.config.x.skip_first_release_gate = true
    Rails.application.config.x.publish_hold = 0
  end

  # Trusted fixture command, never package content: echoes a complete advisory
  # verdict bound to the request SHA without contacting a model or network.
  def passing_adapter
    %q(ruby -rjson -e 'request = JSON.parse(STDIN.read); puts JSON.generate({verdict: "pass", reasons: [], coverage: {complete: true, archive_sha256: request.fetch("sha256")}})')
  end

  def submit(files: nil, seed: false, version: "1.0.0")
    Registry::PublishVersion.new(user: seed ? Registry::SeedCatalog.system_user : @dev, publisher: @publisher,
      plugin_name: "weather", tarball_bytes: TarballBuilder.build(manifest: TarballBuilder.manifest(version:), **(files ? { files: } : {})),
      system_seed: seed, seed_provenance: seed ? { "legacy" => { "verified" => true } } : nil).call
  end

  test "AI pass cannot approve a first executable release including a verified seed" do
    Rails.application.config.x.skip_first_release_gate = false
    Rails.application.config.x.ai_review_command = passing_adapter
    version = submit(seed: true)
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_equal "pass", version.scan_results.dig("ai", "verdict")
    assert_includes version.review_notes, "human review"
  end

  test "AI pass without exact-archive coverage remains quarantined" do
    Rails.application.config.x.ai_review_command = %q(ruby -rjson -e 'puts JSON.generate({verdict: "pass", reasons: []})')
    version = submit
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_includes version.review_notes, "complete coverage"
  end

  test "passing AI cannot waive human judgment for unchanged dynamic call sites" do
    files = { "Widget.qml" => "import QtQuick\nItem { Process { command: clockCommand } }\n" }
    baseline = submit(files:)
    Registry::ReviewJob.perform_now(baseline)
    assert baseline.reload.published?
    Rails.application.config.x.skip_first_release_gate = false
    Rails.application.config.x.ai_review_command = passing_adapter
    version = submit(files:, version: "1.1.0")
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_equal "pass", version.scan_results.dig("ai", "verdict")
    assert_empty version.scan_results["capability_growth"]
    assert_includes version.review_notes, "dynamic execution/network"
  end

  test "documentation gets behavioral checks even for plain explanatory prose" do
    version = submit(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
                             "README.md" => "This package documents access to ~/.ssh/id_ed25519.\n" })
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_includes version.scan_results["findings"].map { |finding| finding["rule"] }, "credential-paths"
  end

  test "review cannot clear bytes that differ from the recorded archive checksum" do
    version = submit
    version.update!(sha256: "f" * 64)
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_includes version.review_notes, "integrity"
    assert_not DataPlane.root.join(version.tarball_path).exist?
  end

  test "legacy evidence cannot override an AI flag" do
    Rails.application.config.x.ai_review_command = %q(ruby -rjson -e 'puts JSON.generate({verdict: "flag", reasons: ["human review needed"]})')
    version = submit(seed: true)
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_includes version.review_notes, "ai review flagged"
  end

  test "legacy evidence cannot waive incomplete scanner coverage" do
    version = submit(seed: true, files: { "Widget.qml" => "import QtQuick\nItem {}\n",
                                        "tests/notes.txt" => "ordinary text\n" * 45_000 })
    Registry::ReviewJob.perform_now(version)
    assert version.reload.quarantined?
    assert_includes version.scan_results["findings"].map { |finding| finding["rule"] }, "scan-truncated"
  end

  test "direct release and stale scheduled work cannot release quarantine" do
    version = submit
    version.update!(state: :held, hold_until: 1.minute.ago)
    stale = PluginVersion.find(version.id)
    version.update!(state: :quarantined, hold_until: nil)
    Registry::ReleaseJob.perform_now(stale)
    assert version.reload.quarantined?
    assert_raises(ArgumentError) { Registry::ReleaseVersion.call(stale) }
    assert_not DataPlane.root.join(version.tarball_path).exist?
  end

  test "release service itself respects an unexpired hold" do
    version = submit
    version.update!(state: :held, hold_until: 1.hour.from_now)
    Registry::ReleaseVersion.call(version)
    assert version.reload.held?
    assert_not DataPlane.root.join(version.tarball_path).exist?
  end

  test "rejection invalidates later approval and queued release" do
    version = submit
    version.update!(state: :quarantined)
    sign_in_as @admin
    post reject_admin_version_path(version), params: { reason: "needs changes" }
    post approve_admin_version_path(version)
    Registry::ReleaseJob.perform_now(version)
    assert version.reload.rejected?
    assert_nil version.approved_at
    assert_not AuditEvent.exists?(subject: version, action: "version.approve")
  end

  test "source excerpts disclose full size and offer exact archive access" do
    version = submit(files: { "Widget.qml" => "import QtQuick\nItem {}\n", "notes.txt" => "ordinary text\n" * 3000 })
    sign_in_as @admin
    get admin_version_path(version)
    assert_response :success
    assert_select ".badge--warning", text: /Incomplete excerpt/
    assert_select "a[href=?]", download_tarball_admin_version_path(version)
  end
end
