require "test_helper"

# Round 40: credential liveness at release, signed-state monotonicity across
# database restores, orphan survival through the external import task, and
# self-healing of a write interrupted between sig and content promotion.
class MomusRoundFortyTest < ActionDispatch::IntegrationTest
  setup do
    @dev = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @dev, role: :owner, founding: true)
  end

  teardown do
    Rails.application.config.x.enforce_review_policy = false
    Rails.application.config.x.publish_hold = 0
  end

  test "a token revoked during the hold window quarantines the release instead of shipping" do
    Rails.application.config.x.publish_hold = 1.hour
    token = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "weather")
    post "/api/v1/plugins/acme/weather/versions", params: TarballBuilder.build,
      headers: { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/gzip" }
    assert_response :created
    perform_enqueued_jobs(at: Time.current)
    version = PluginVersion.last
    assert version.reload.held?
    assert_equal token, version.api_token

    token.revoke!
    Registry::ReleaseVersion.call(version)
    assert version.reload.quarantined?, "revoked credential must divert the release to human review"
    assert_includes version.review_notes, "credential revoked"
    assert_not DataPlane.root.join(version.tarball_path).exist?
  end

  test "removing a trusted publisher revokes its minted tokens, stopping held releases" do
    Rails.application.config.x.publish_hold = 1.hour
    token = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "weather")
    token.update!(provenance: { "repository" => "acme/weather" })
    post "/api/v1/plugins/acme/weather/versions", params: TarballBuilder.build,
      headers: { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/gzip" }
    assert_response :created
    perform_enqueued_jobs(at: Time.current)
    version = PluginVersion.last
    assert version.reload.held?

    # Registration removal revokes provenance-bearing tokens (controller path);
    # the same revocation state must stop the pipeline release
    token.revoke!
    Registry::ReleaseVersion.call(version)
    assert version.reload.quarantined?
  end

  test "a yank never reverts across a database restore" do
    version = publish!("weather")
    version.yank!(reason: "bad", actor: @dev)
    DataPlane::Regenerate.all

    # Simulate restoring a backup taken before the yank
    version.reload.update!(state: :published, yanked_at: nil, yank_reason: nil)
    DataPlane::Regenerate.all

    assert version.reload.yanked?, "signed yank state is monotonic"
    entry = DataPlane.read("index/acme/weather.json").each_line
      .map { |l| JSON.parse(l) }.find { |e| e["vers"] == "1.0.0" }
    assert entry["yanked"]
  end

  test "a version reverted to pre-publication limbo fails regeneration closed" do
    version = publish!("widget")
    version.reload.update!(state: :processing, published_at: nil)

    assert_raises(DataPlane::Regenerate::IndexContinuityError) { DataPlane::Regenerate.all }
  end

  test "import_revocations preserves orphan entries even when the data plane was lost" do
    entries = [ { "plugin" => "ghost.plugin", "version" => "1.0.0", "reason" => "malware",
                  "revoked_at" => Time.current.utc.iso8601 } ]
    # No plugin row, no surviving data-plane files — the worst restore case
    generator = DataPlane::Regenerate.new
    generator.import_revocation_entries(entries)
    DataPlane::Regenerate.all(generator)

    written = JSON.parse(DataPlane.read("revocations.json"))["revocations"]
    assert written.any? { |e| e["plugin"] == "ghost.plugin" && e["version"] == "1.0.0" },
      "externally imported orphan revocations must land in the freshly written kill list"
  end

  test "a write interrupted between sig and content promotion heals instead of wedging" do
    publish!("gadget")
    original = DataPlane.read("revocations.json")

    # Simulate the crash window: new sig live, old content live, staged content present
    newer = JSON.generate(JSON.parse(original).merge("note" => "next-generation"))
    DataPlane.atomic_write("revocations.json.staged", newer)
    DataPlane.atomic_write("revocations.json.sig", DataPlane::Signer.sign_base64(newer))

    DataPlane::Regenerate.all
    content = DataPlane.read("revocations.json")
    assert DataPlane::Signer.verify?(content, DataPlane.read("revocations.json.sig")),
      "regeneration completes and leaves a verifiable pair"
  end

  private

  def publish!(name)
    version = nil
    perform_enqueued_jobs do
      version = Registry::PublishVersion.new(user: @dev, publisher: @publisher, plugin_name: name,
        tarball_bytes: TarballBuilder.build(manifest: TarballBuilder.manifest(id: "acme.#{name}"))).call
    end
    version.reload
  end
end
