require "test_helper"

# Unreleased plugins are private to publisher members + admins; version
# history is browsable with per-version pages and pinned installs.
class PluginVisibilityAndVersionsTest < ActionDispatch::IntegrationTest
  include SessionTestHelper

  setup do
    @publisher = Publisher.create!(name: "acme", kind: :org)
    @member = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    Membership.create!(publisher: @publisher, user: @member, role: :owner, founding: true)
    @admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @outsider = User.create!(email_address: "other@example.com", name: "Other",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)

    # Never released: one version stuck in quarantine
    @pending = Plugin.create!(publisher: @publisher, name: "telemetry", state: :quarantined, summary: "Pending")
    @pending.versions.create!(version: "0.1.0", manifest: {}, sha256: "a" * 64, size_bytes: 1, state: :quarantined)

    # Released with history: 1.0.0 published, 1.1.0 yanked, 1.2.0 published, 2.0.0 in review
    @released = Plugin.create!(publisher: @publisher, name: "weather", summary: "Forecast", latest_version: "1.2.0")
    @released.versions.create!(version: "1.0.0", manifest: { "kinds" => [ "bar-widget" ] }, sha256: "0" * 64,
      size_bytes: 100, state: :published, published_at: 3.months.ago, license: "MIT")
    @released.versions.create!(version: "1.1.0", manifest: {}, sha256: "1" * 64,
      size_bytes: 100, state: :yanked, published_at: 2.months.ago, yanked_at: 1.month.ago, yank_reason: "broke bars")
    @released.versions.create!(version: "1.2.0", manifest: {}, sha256: "2" * 64,
      size_bytes: 100, state: :published, published_at: 1.week.ago, license: "MIT")
    @released.versions.create!(version: "2.0.0", manifest: {}, sha256: "3" * 64, size_bytes: 100, state: :held)
  end

  test "an unreleased plugin 404s publicly and for unrelated users" do
    get plugin_path("acme", "telemetry")
    assert_response :not_found

    sign_in_as @outsider
    get plugin_path("acme", "telemetry")
    assert_response :not_found
  end

  test "publisher members and admins still see an unreleased plugin, with a notice" do
    sign_in_as @member
    get plugin_path("acme", "telemetry")
    assert_response :success
    assert_match "Not public yet", response.body

    sign_in_as @admin
    get plugin_path("acme", "telemetry")
    assert_response :success
  end

  test "unreleased plugins stay out of directory, sitemap, and feed" do
    get root_path
    assert_no_match(/telemetry/, response.body)
    get "/sitemap.xml"
    assert_no_match(/telemetry/, response.body)
  end

  test "the public version list hides in-flight versions; members see them" do
    get plugin_path("acme", "weather")
    assert_response :success
    assert_no_match(/2\.0\.0/, response.body)
    assert_match "1.2.0", response.body
    assert_match "1.1.0", response.body

    sign_in_as @member
    get plugin_path("acme", "weather")
    assert_match "2.0.0", response.body
  end

  test "version rows link to a version page with a pinned install command" do
    get plugin_path("acme", "weather")
    assert_select ".version-list a[href=?]", plugin_version_path("acme", "weather", "1.0.0")

    get plugin_version_path("acme", "weather", "1.0.0")
    assert_response :success
    assert_match "omarchy plugin add acme/weather@1.0.0", response.body
    assert_match "Older version", response.body
    assert_match "Pins this release", response.body
    assert_match "0" * 12, response.body
    assert_select "a[href=?]", "/dl/acme/weather/weather-1.0.0.tar.gz"
    # Mirrors the plugin page: install strip + readme article + sidebar sections
    assert_select ".plugin-layout .readme"
    assert_select ".install-strip"
  end

  test "a yanked version page shows the withdrawal, not an install command" do
    get plugin_version_path("acme", "weather", "1.1.0")
    assert_response :success
    assert_match "broke bars", response.body
    assert_no_match(/omarchy plugin add acme\/weather@1\.1\.0/, response.body)
  end

  test "in-flight version pages 404 publicly but load for members" do
    get plugin_version_path("acme", "weather", "2.0.0")
    assert_response :not_found

    sign_in_as @member
    get plugin_version_path("acme", "weather", "2.0.0")
    assert_response :success
    assert_match "has not cleared review", response.body
  end
end
