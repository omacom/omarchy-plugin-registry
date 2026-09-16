require "test_helper"

# Proves automatic first release with complete AI evidence and the optional
# hold window, using a trusted model fixture rather than a provider.
class ProductionReleaseSequenceTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.enforce_review_policy = true
    Rails.application.config.x.ai_review_command = AiReviewFixture.command
    Rails.application.config.x.publish_hold = 15.minutes

    @admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @dev = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @dev, role: :owner, founding: true)
    @token = ApiToken.mint!(user: @dev, publisher: @publisher, plugin_name: "weather")
  end

  teardown do
    Rails.application.config.x.enforce_review_policy = false
    Rails.application.config.x.ai_review_command = nil
    Rails.application.config.x.publish_hold = 0
  end

  test "first release: complete automated review -> hold window -> live, without human approval" do
    post "/api/v1/plugins/acme/weather/versions", params: TarballBuilder.build,
      headers: { "Authorization" => "Bearer #{@token.plaintext_token}", "Content-Type" => "application/gzip" }
    assert_response :created
    perform_enqueued_jobs(at: Time.current) # review runs now; nothing future runs early
    version = PluginVersion.last

    # Complete checks enter the hold without manufacturing human approval.
    assert version.automated_review_passed?
    assert_nil version.approved_at
    assert version.reload.held?
    assert version.hold_until.future?
    assert_not DataPlane.root.join(version.tarball_path).exist?
    get "/dl/acme/weather/weather-1.0.0.tar.gz"
    assert_response :not_found

    # 3. Only the elapsed hold releases it — via the JOB THE PIPELINE ITSELF
    # SCHEDULED, not a manually enqueued stand-in. Before the hold elapses,
    # performing only due jobs releases nothing:
    perform_enqueued_jobs(at: Time.current)
    assert version.reload.held?

    travel_to 16.minutes.from_now
    perform_enqueued_jobs(at: Time.current)
    assert version.reload.published?
    perform_enqueued_jobs(at: Time.current) # the regeneration the release enqueued
    assert DataPlane.root.join(version.tarball_path).exist?
    entry = JSON.parse(DataPlane.read("index/acme/weather.json").lines.second)
    assert_equal version.sha256, entry["sha256"]
    assert_not AuditEvent.exists?(action: "version.approve", public: true)
    assert AuditEvent.exists?(action: "version.publish", public: true)
  end

  test "clean update with a published baseline still waits out the hold" do
    # Seed a published baseline under production rules (AI checks + hold)
    post "/api/v1/plugins/acme/weather/versions", params: TarballBuilder.build,
      headers: { "Authorization" => "Bearer #{@token.plaintext_token}", "Content-Type" => "application/gzip" }
    perform_enqueued_jobs(at: Time.current)
    v1 = PluginVersion.last
    travel_to 16.minutes.from_now
    perform_enqueued_jobs(at: Time.current) # the job approval scheduled
    assert v1.reload.published?

    # The identical-capability update skips the human but NOT the hold
    # (non-block time travel; travel_back runs automatically in teardown)
    travel 5.minutes
    post "/api/v1/plugins/acme/weather/versions",
      params: TarballBuilder.build(manifest: TarballBuilder.manifest(version: "1.1.0")),
      headers: { "Authorization" => "Bearer #{@token.plaintext_token}", "Content-Type" => "application/gzip" }
    perform_enqueued_jobs(at: Time.current) # review runs now; release is scheduled ahead
    v2 = PluginVersion.find_by(version: "1.1.0")
    assert v2.held?
    assert v2.hold_until.future?

    travel 16.minutes
    perform_enqueued_jobs(at: Time.current) # the pipeline's own scheduled release
    assert v2.reload.published?
  end
end
