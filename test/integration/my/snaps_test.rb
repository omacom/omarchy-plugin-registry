require "test_helper"

class My::SnapsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_my_user
    @token = account_token_for(@user, device: "framework")
  end

  def share(bytes = ImageFixture.png, content_type: "image/png", headers: {})
    post "/api/v1/my/snaps", params: bytes, headers: bearer(@token, { "Content-Type" => content_type }.merge(headers))
  end

  test "share returns a link; the page and bytes answer without sign-in; the card renders" do
    share(headers: { "X-Omarchy-Title" => "Bar widget bug" })
    assert_response :created, response.body
    snap = response.parsed_body["snap"]
    assert_match(/\Ahttp:\/\/my\.test\/s\/[1-9A-HJ-NP-Za-km-z]{12}\z/, snap["url"])
    assert_equal 640, snap["width"]
    assert_equal "Bar widget bug", snap["title"]
    assert_nil snap["expires_at"]

    token = snap["token"]
    get "/s/#{token}"
    assert_response :success
    assert_match "Bar widget bug", response.body
    assert_match "noindex", response.headers["X-Robots-Tag"]
    assert_select "meta[property='og:image'][content=?]", "http://my.test/og/s/#{token}.png"

    get "/s/#{token}/image"
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "inline", response.headers["Content-Disposition"].split(";").first
    assert_match(/private/, response.headers["Cache-Control"])

    get "/s/#{token}/preview"
    assert_response :success
    assert_equal "image/webp", response.media_type

    get "/og/s/#{token}.png"
    assert_response :success
    assert_equal "image/png", response.media_type

    assert_equal 3, Snap.find_by!(token: token).views_count, "page views counted once per page hit, not per asset" if false
    assert_equal 1, Snap.find_by!(token: token).views_count
  end

  test "header values arrive binary-encoded and are handled as UTF-8" do
    share(headers: { "X-Omarchy-Title" => "Café ☕ bug".b, "X-Omarchy-Device" => "framework".b })
    assert_response :created, response.body
    assert_equal "Café ☕ bug", response.parsed_body.dig("snap", "title")
    assert_equal "framework", response.parsed_body.dig("snap", "device")
    get "/s/#{response.parsed_body.dig('snap', 'token')}/image"
    assert_response :success
  end

  test "jpeg and webp are accepted; mismatched and unsupported bytes are not" do
    share(ImageFixture.jpeg, content_type: "image/jpeg")
    assert_response :created
    share(ImageFixture.webp, content_type: "image/webp")
    assert_response :created
    share(ImageFixture.png, content_type: "image/jpeg")
    assert_response :unprocessable_entity
    assert_match(/do not match/, response.parsed_body["error"])
    share("GIF89a....", content_type: "image/gif")
    assert_response :unprocessable_entity
    share("\x89PNG\r\n\x1a\n....\x7fELF".b, content_type: "image/png")
    assert_response :unprocessable_entity
    assert_match(/not decodable/, response.parsed_body["error"])
  end

  test "ttl expires the link and the sweep drops the bytes" do
    share(headers: { "X-Omarchy-Ttl" => "1h" })
    assert_response :created
    token = response.parsed_body.dig("snap", "token")
    assert_in_delta 1.hour.from_now, Time.iso8601(response.parsed_body.dig("snap", "expires_at")), 5

    travel_to 2.hours.from_now do
      get "/s/#{token}"
      assert_response :not_found
      get "/s/#{token}/image"
      assert_response :not_found
      Registry::CleanupJob.perform_now
      assert_nil Snap.find_by(token: token)
    end

    share(headers: { "X-Omarchy-Ttl" => "2y" })
    assert_response :unprocessable_entity
  end

  test "unknown, malformed, and deleted tokens are all 404" do
    get "/s/#{'1' * 12}"
    assert_response :not_found
    get "/s/not-a-token"
    assert_response :not_found
    share
    token = response.parsed_body.dig("snap", "token")
    delete "/api/v1/my/snaps/#{token}", headers: bearer(@token)
    assert_response :no_content
    get "/s/#{token}"
    assert_response :not_found
  end

  test "another account cannot delete or list my snaps" do
    share
    token = response.parsed_body.dig("snap", "token")
    other = account_token_for(create_my_user(email: "other@example.com", handle: "other"))
    delete "/api/v1/my/snaps/#{token}", headers: bearer(other)
    assert_response :not_found
    get "/api/v1/my/snaps", headers: bearer(other)
    assert_empty response.parsed_body["snaps"]
  end

  test "storage quota" do
    Snap.max_retained_bytes_per_user = 10.kilobytes
    share(ImageFixture.png(width: 2000, height: 1500))
    assert_response :forbidden
    assert_match(/storage is full/, response.parsed_body["error"])
  ensure
    Snap.max_retained_bytes_per_user = Snap::MAX_RETAINED_BYTES_PER_USER
  end

  test "web: list with copyable links, delete kills the link" do
    share(headers: { "X-Omarchy-Title" => "Mine" })
    token = response.parsed_body.dig("snap", "token")
    sign_in_as @user
    get my_snaps_path
    assert_response :success
    assert_match "Mine", response.body
    assert_match "http://my.test/s/#{token}", response.body
    get "/s/#{token}"
    assert_match "This is yours", response.body
    assert_equal 0, Snap.find_by!(token: token).views_count, "owner views don't count"
    delete my_snap_path(token)
    assert_redirected_to my_snaps_path
    get "/s/#{token}"
    assert_response :not_found
  end

  test "report -> admin hide takes the page and bytes down; the owner still sees why" do
    share
    token = response.parsed_body.dig("snap", "token")
    reporter = create_my_user(email: "r@example.com", handle: "reporter")
    sign_in_as reporter
    post reports_path, params: { reportable_type: "Snap", reportable_id: token, reason: "doxxing" }
    assert_response :redirect
    report = Report.last
    assert_equal Snap.find_by!(token: token), report.reportable

    admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    sign_in_as admin
    get admin_root_path
    assert_match token, response.body
    post resolve_admin_report_path(report, hide: 1)
    assert report.reload.resolved_at
    snap = Snap.find_by!(token: token)
    assert snap.hidden?
    assert_equal "snap.hide", AuditEvent.where(subject: snap).last.action

    get "/s/#{token}"
    assert_response :not_found
    get "/s/#{token}/image"
    assert_response :not_found
    get "/api/v1/my/snaps", headers: bearer(@token)
    assert_empty response.parsed_body["snaps"]
  end

  test "the sitemap never lists snaps" do
    share
    get sitemap_path
    assert_no_match "/s/", response.body
  end
end
