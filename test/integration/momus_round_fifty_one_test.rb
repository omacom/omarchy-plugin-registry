require "test_helper"

# Round 51: the external witness gates post-restore regeneration, approval
# authority is revalidated at release, and pathological SPDX input is a
# validation error rather than a stack overflow.
class MomusRoundFiftyOneTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @dev = User.create!(email_address: "dev@example.com", name: "Dev", verified_at: Time.current,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @dev, role: :owner, founding: true)
  end

  teardown do
    Rails.application.config.x.enforce_review_policy = false
    Rails.application.config.x.publish_hold = 0
  end

  test "the witness refuses to sign a newer kill list over a restored volume" do
    witness = File.join(Dir.mktmpdir, "witness.json")
    with_env("REGISTRY_WITNESS_PATH" => witness) do
      publish!("weather")
      recorded = JSON.parse(File.read(witness))
      assert recorded["generation"].positive?

      # Full-volume restore to a pre-revocation state: witness (external)
      # remembers a newer generation than the restored data plane holds
      File.write(witness, JSON.generate("generation" => recorded["generation"] + 999_999))
      assert_raises(DataPlane::Regenerate::StaleRestoreError) { DataPlane::Regenerate.all }

      # Deliberate operator override still works, exactly once per ack
      with_env("REGISTRY_RESTORE_ACK" => "1") { DataPlane::Regenerate.all }
    end
  end

  test "approval by a since-suspended admin re-quarantines instead of publishing" do
    Rails.application.config.x.publish_hold = 1.hour
    token = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "widget")
    post "/api/v1/plugins/acme/widget/versions",
      params: TarballBuilder.build(manifest: TarballBuilder.manifest(id: "acme.widget")),
      headers: { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/gzip" }
    assert_response :created
    perform_enqueued_jobs(at: Time.current)
    version = PluginVersion.last
    assert version.reload.held?

    version.update!(state: :quarantined, hold_until: nil)
    sign_in_as @admin
    post approve_admin_version_path(version)
    assert version.reload.held?
    assert_equal @admin, version.approved_by

    # The approver is contained during the hold window
    @admin.update!(suspended_at: Time.current)
    travel_to version.hold_until + 1.minute do
      Registry::ReleaseVersion.call(version)
    end
    assert version.reload.quarantined?, "dead approval authority must not publish"
    assert_includes version.review_notes, "no longer authorized"
  end

  test "a deeply nested SPDX expression is a clean validation error" do
    bomb = ("(" * 5000) + "MIT" + (")" * 5000)
    error = assert_raises(Registry::PublishVersion::PublishError) do
      Registry::PublishVersion.new(user: @dev, publisher: @publisher, plugin_name: "weather",
        tarball_bytes: TarballBuilder.build(manifest: TarballBuilder.manifest(license: bomb))).call
    end
    assert_match(/SPDX/, error.message)
  end

  private

  def with_env(vars)
    old = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def publish!(name)
    version = nil
    perform_enqueued_jobs do
      version = Registry::PublishVersion.new(user: @dev, publisher: @publisher, plugin_name: name,
        tarball_bytes: TarballBuilder.build(manifest: TarballBuilder.manifest(id: "acme.#{name}"))).call
    end
    version.reload
  end
end
