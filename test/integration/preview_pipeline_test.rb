require "test_helper"
require "vips"

class PreviewPipelineTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "dev@example.com",
      name: "Dev", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @user, role: :owner, founding: true)
    @token = ApiToken.mint!(user: @user, publisher: @publisher, plugin_name: "weather")
  end

  def publish(bytes, kind: "plugin")
    post "/api/v1/#{kind}s/acme/weather/versions", params: bytes,
      headers: { "Authorization" => "Bearer #{@token.plaintext_token}", "Content-Type" => "application/gzip" }
  end

  def png_bytes(width: 1280, height: 720)
    Vips::Image.black(width, height).add(60).cast("uchar").pngsave_buffer
  end

  test "a published preview lands in the directory and the plugin page" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: {
        "Widget.qml" => "import QtQuick\nItem {}\n", "preview.png" => png_bytes })
    end
    assert_response :created

    plugin = Plugin.find_by!(name: "weather")
    assert plugin.preview?, "expected preview renditions after release"
    assert plugin.preview_detail.attached?
    assert_equal 720, plugin.preview_card_meta["width"]
    assert_equal "preview.png", plugin.preview_meta["source"]

    get "/"
    assert_select ".plugin-card__preview"
    get "/plugins/acme/weather"
    assert_select "button.plugin-preview[aria-label='Enlarge acme/weather screenshot 1 of 1']" do
      assert_select "img[width][height]", 1
    end
    assert_select "dialog.lightbox" do
      assert_select "img[width][height]", 1
    end
  end

  test "the plugin page falls back to the card rendition when detail is unavailable" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: {
        "Widget.qml" => "import QtQuick\nItem {}\n", "preview.png" => png_bytes })
    end
    plugin = Plugin.find_by!(name: "weather")
    plugin.preview_detail.purge

    get plugin_path("acme", "weather")

    assert_response :success
    assert_select "button.plugin-preview" do
      assert_select "img[src=?]", rails_storage_proxy_path(plugin.preview_card), count: 1
    end
    assert_select "dialog.lightbox img[src=?]", rails_storage_proxy_path(plugin.preview_card), count: 1

    plugin.update_columns(preview_meta: {})
    get plugin_path("acme", "weather")
    assert_select ".plugin-preview, dialog.lightbox", count: 0
  end

  test "an update without a preview clears the old renditions" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: {
        "Widget.qml" => "import QtQuick\nItem {}\n", "preview.png" => png_bytes, "preview2.png" => png_bytes })
    end
    assert Plugin.find_by!(name: "weather").preview?

    perform_enqueued_jobs do
      publish TarballBuilder.build(manifest: TarballBuilder.manifest(version: "1.1.0"))
    end
    assert_response :created

    plugin = Plugin.find_by!(name: "weather")
    assert_not plugin.preview?
    assert_not plugin.preview_card.attached?
    assert_empty plugin.preview_screenshots
    assert_empty plugin.screenshot_previews
    assert_equal({}, plugin.preview_meta)
  end

  test "rejects a corrupt preview at upload time with a clear error" do
    publish TarballBuilder.build(files: {
      "Widget.qml" => "import QtQuick\nItem {}\n", "preview.png" => "GIF89a definitely not a png" })
    assert_response :unprocessable_entity
    assert_match(/does not contain PNG data/, response.parsed_body["error"])
    assert_nil Plugin.find_by(name: "weather")&.versions&.first
  end

  test "rejects a tarball shipping two preview candidates" do
    publish TarballBuilder.build(files: {
      "Widget.qml" => "import QtQuick\nItem {}\n",
      "preview.png" => png_bytes, "preview.gif" => png_bytes })
    assert_response :unprocessable_entity
    assert_match(/multiple preview images/, response.parsed_body["error"])
  end

  %w[plugin theme].each do |kind|
    test "#{kind} publishes four ordered screenshots across JSON and HTML" do
      manifest = TarballBuilder.manifest
      files = { "Widget.qml" => "import QtQuick\nItem {}\n" }
      if kind == "theme"
        manifest = TarballBuilder.manifest(packageType: "theme", kinds: [ "theme" ], entryPoints: { "theme" => "colors.toml" })
        files = { "colors.toml" => Registry::ThemeValidator::REQUIRED_COLORS.map { |key| "#{key} = \"#112233\"\n" }.join }
      end
      # Tar order must not determine the cover or gallery order.
      [ 4, 2, 1, 3 ].each { |slot| files["preview#{slot}.png"] = png_bytes(width: 800 + slot, height: 500) }
      perform_enqueued_jobs { publish(TarballBuilder.build(manifest:, files:), kind:) }
      assert_response :created
      plugin = Plugin.find_by!(name: "weather")
      assert_equal "preview1.png", plugin.preview_meta["source"]
      assert_equal 3, plugin.preview_screenshots.size
      assert_equal %w[preview1.png preview2.png preview3.png preview4.png], plugin.screenshot_previews.map { |s| s[:meta]["source"] }

      [ "/#{kind}s/acme/weather.json", "/#{kind}s/acme/weather/1.0.0.json" ].each do |path|
        get path
        assert_response :success
        entry = response.parsed_body.fetch("plugin")
        assert_equal %w[preview1.png preview2.png preview3.png preview4.png], entry.fetch("screenshots").pluck("source")
        assert_equal [ 801, 802, 803, 804 ], entry["screenshots"].pluck("width")
        assert_equal entry.dig("preview", "detail", "url"), entry["screenshots"].first["url"]
        entry["screenshots"].each do |screenshot|
          assert_match %r{\Ahttp://registry\.test/rails/active_storage/}, screenshot["url"]
          assert_equal false, screenshot["animated"]
        end
      end
      get "/#{kind}s.json"
      assert_equal 4, response.parsed_body.fetch("#{kind}s").sole.fetch("screenshots").size
      get "/publishers/acme.json"
      assert_equal 4, response.parsed_body.fetch("#{kind}s").sole.fetch("screenshots").size
      get "/#{kind}s/acme/weather"
      assert_select ".screenshot-gallery .plugin-preview", count: 4
      assert_select "dialog.lightbox", count: 4

      preloaded = Plugin.with_previews.find(plugin.id)
      assert_no_queries { assert_equal 4, preloaded.screenshot_previews.size }
    end
  end

  test "legacy cover can be followed by numbered screenshots and gaps sort numerically" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
        "preview4.png" => png_bytes, "preview.png" => png_bytes, "preview2.png" => png_bytes })
    end
    assert_response :created
    get "/plugins/acme/weather.json"
    assert_equal %w[preview.png preview2.png preview4.png], response.parsed_body.dig("plugin", "screenshots").pluck("source")
  end

  test "duplicate slots and out of range numbered screenshots fail before creating a release" do
    [ %w[preview.png preview1.png], %w[preview2.png preview2.jpg], %w[preview0.png], %w[preview5.png], %w[preview01.png] ].each do |names|
      publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n" }.merge(names.index_with { png_bytes }))
      assert_response :unprocessable_entity
    end
    assert_equal 0, PluginVersion.count
  end

  test "a corrupt secondary screenshot rejects the whole submission" do
    publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
      "preview1.png" => png_bytes, "preview2.png" => "not a PNG" })
    assert_response :unprocessable_entity
    assert_match "preview2.png", response.parsed_body["error"]
    assert_equal 0, PluginVersion.count
  end

  test "the per-image byte limit applies to numbered screenshots" do
    publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
      "preview4.png" => "x" * (Registry::TarballInspector::MAX_PREVIEW_BYTES + 1) })
    assert_response :unprocessable_entity
    assert_match "preview4.png exceeds", response.parsed_body["error"]
  end

  test "unpublished screenshots do not replace the public gallery and yanking restores it" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n", "preview.png" => png_bytes })
    end
    publish TarballBuilder.build(manifest: TarballBuilder.manifest(version: "1.1.0"),
      files: { "Widget.qml" => "import QtQuick\nItem {}\n", "preview1.png" => png_bytes, "preview2.png" => png_bytes })
    plugin = Plugin.find_by!(name: "weather")
    assert_equal [ "preview.png" ], plugin.screenshot_previews.map { |s| s[:meta]["source"] }
    perform_enqueued_jobs { Registry::ReviewJob.perform_now(plugin.versions.processing.sole) }
    assert_equal 2, plugin.reload.screenshot_previews.size
    perform_enqueued_jobs { plugin.latest_published_version.yank!(reason: "replacement needed", actor: @user) }
    assert_equal [ "preview.png" ], plugin.reload.screenshot_previews.map { |s| s[:meta]["source"] }
    assert_empty plugin.preview_screenshots
  end

  test "a takedown during processing cannot restore the public screenshots" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n", "preview1.png" => png_bytes })
    end
    plugin = Plugin.find_by!(name: "weather")
    process = Registry::PreviewImage.method(:process)
    during_processing = lambda do |bytes, name:|
      plugin.update!(state: :security_holding, latest_version: nil)
      process.call(bytes, name:)
    end
    with_preview_processor(during_processing) do
      Registry::RefreshPreviewJob.perform_now(plugin)
    end
    assert_empty plugin.reload.screenshot_previews
    Registry::RefreshPreviewJob.perform_now(plugin)
    assert_not plugin.reload.preview_detail.attached?
    assert_empty plugin.preview_screenshots
    get "/plugins/acme/weather.json"
    assert_empty response.parsed_body.dig("plugin", "screenshots")
  end

  test "failure on a secondary rendition clears the whole gallery instead of publishing a partial one" do
    perform_enqueued_jobs do
      publish TarballBuilder.build(files: { "Widget.qml" => "import QtQuick\nItem {}\n",
        "preview1.png" => png_bytes, "preview2.png" => png_bytes })
    end
    plugin = Plugin.find_by!(name: "weather")
    process = Registry::PreviewImage.method(:process)
    partial_failure = lambda do |bytes, name:|
      raise Registry::PreviewImage::InvalidPreview, "synthetic processor failure" if name == "preview2.png"
      process.call(bytes, name:)
    end
    with_preview_processor(partial_failure) do
      Registry::RefreshPreviewJob.perform_now(plugin)
    end
    assert_empty plugin.reload.screenshot_previews
    assert_not plugin.preview_card.attached?
    assert_not plugin.preview_detail.attached?
    assert_empty plugin.preview_screenshots
  end

  private

  def with_preview_processor(replacement)
    original = Registry::PreviewImage.method(:process)
    Registry::PreviewImage.define_singleton_method(:process, replacement)
    yield
  ensure
    Registry::PreviewImage.define_singleton_method(:process, original)
  end
end
