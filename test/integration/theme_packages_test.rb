require "test_helper"

class ThemePackagesTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "themes@example.com", name: "Themes",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @user, role: :owner, founding: true)
    @token = ApiToken.mint!(user: @user)
    @manifest = TarballBuilder.manifest(packageType: "theme", kinds: [ "theme" ], entryPoints: { "theme" => "colors.toml" })
    @palette = Registry::ThemeValidator::REQUIRED_COLORS.map { |key| "#{key} = \"#112233\"\n" }.join
  end

  def publish_theme(manifest: @manifest, files: { "colors.toml" => @palette }, endpoint: "themes")
    post "/api/v1/#{endpoint}/acme/weather/versions", params: TarballBuilder.build(manifest:, files:),
      headers: { "Authorization" => "Bearer #{@token.plaintext_token}", "Content-Type" => "application/gzip" }
  end

  test "a theme clears the shared pipeline and ships signed bytes and theme install commands" do
    perform_enqueued_jobs { publish_theme }
    assert_response :created
    assert_equal "theme", response.parsed_body["package_type"]
    theme = Plugin.find_by!(name: "weather")
    assert theme.theme?
    assert theme.versions.first.published?
    index = DataPlane.read("index/acme/weather.json")
    assert DataPlane::Signer.verify?(index, DataPlane.read("index/acme/weather.json.sig"))
    entry = JSON.parse(index.lines.second)
    assert_equal "theme", entry["packageType"]
    listing = JSON.parse(DataPlane.read("all.json"))
    assert_empty listing["plugins"]
    assert_equal [ "acme.weather" ], listing["themes"].pluck("id")

    get "/themes/acme/weather.json"
    assert_response :success
    assert_equal "omarchy theme add acme/weather", response.parsed_body.dig("plugin", "install_command")
    get "/themes/acme/weather/1.0.0"
    assert_response :success
    assert_select "[data-clipboard-text-value='omarchy theme add acme/weather@1.0.0']"
    get "/themes.json"
    assert_equal 1, response.parsed_body.dig("page", "total")
    assert_equal [ "acme.weather" ], response.parsed_body["themes"].pluck("id")
    get "/plugins.json"
    assert_empty response.parsed_body["plugins"]
    get "/packages.json"
    assert_equal [ "acme.weather" ], response.parsed_body["packages"].pluck("id")
  end

  test "package type cannot change and typed endpoints cannot be confused" do
    publish_theme(endpoint: "plugins")
    assert_response :unprocessable_entity
    assert_equal 0, Plugin.count
    publish_theme
    assert_response :created
    publish_theme(manifest: TarballBuilder.manifest(version: "2.0.0"), files: { "Widget.qml" => "import QtQuick\nItem {}" }, endpoint: "plugins")
    assert_response :unprocessable_entity
    assert_match "immutable", response.parsed_body["error"]
    assert_equal "theme", Plugin.last.package_type
  end

  test "theme community actions and publisher dashboard return to the theme page" do
    perform_enqueued_jobs { publish_theme }
    sign_in_as @user
    post plugin_comments_path("acme", "weather"), params: { body: "Great palette" }
    assert_redirected_to "/themes/acme/weather"
    post plugin_rating_path("acme", "weather"), params: { value: 5 }
    assert_redirected_to "/themes/acme/weather"
    get dashboard_path
    assert_response :success
    assert_select "a[href='/themes/acme/weather']"
  end

  test "a narrow credential still cannot publish another package" do
    @token = ApiToken.mint!(user: @user, publisher: @publisher, plugin_name: "different")
    publish_theme
    assert_response :forbidden
    assert_equal 0, PluginVersion.count
  end

  test "theme takedown removes discovery and installability and retains the signed revocation" do
    perform_enqueued_jobs { publish_theme }
    theme = Plugin.last
    @user.update!(admin: true)
    sign_in_as @user
    perform_enqueued_jobs do
      post security_hold_admin_plugin_path(theme), params: { reason: "malicious asset" }
    end
    assert_empty JSON.parse(DataPlane.read("all.json"))["themes"]
    assert_equal "acme.weather", JSON.parse(DataPlane.read("revocations.json"))["revocations"].first["plugin"]
    get "/themes/acme/weather.json"
    assert_response :success
    assert_not response.parsed_body.dig("plugin", "installable")
    assert_nil response.parsed_body.dig("plugin", "install_command")
    assert response.parsed_body.dig("plugin", "notices").any?
  end

  test "theme malicious bytes still go through the scanner and review hold" do
    # A PNG-looking executable polyglot is not waved through because themes
    # are declarative. Its full-content marker must quarantine it.
    perform_enqueued_jobs do
      publish_theme(files: { "colors.toml" => @palette,
        "backgrounds/evil.png" => "\x89PNG\r\n\x1a\n".b + "\x7fELF".b })
    end
    assert_response :created
    assert PluginVersion.last.quarantined?
    assert_nil Plugin.last.latest_version
    get "/themes/acme/weather.json"
    assert_response :not_found
  end

  test "client receipts cannot be smuggled into an archive" do
    publish_theme(files: { "colors.toml" => @palette, ".registry-receipt.json" => '{"source":"registry"}' })
    assert_response :unprocessable_entity
    assert_match "reserved", response.parsed_body["error"]
  end

  test "theme boot artwork uses the same declarative image allowance" do
    publish_theme(files: { "colors.toml" => @palette,
      "preview-unlock.png" => "\x89PNG\r\n\x1a\n".b, "unlock.png" => "\x89PNG\r\n\x1a\n".b })
    assert_response :created
    assert Plugin.last.theme?
  end
end
