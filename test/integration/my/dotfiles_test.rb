require "test_helper"

class My::DotfilesTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_my_user
    @token = account_token_for(@user, device: "xps-14")
  end

  test "push, list, show, download round trip" do
    bytes = dotfile_bundle_bytes
    post "/api/v1/my/dotfiles", params: bytes, headers: bearer(@token,
      "Content-Type" => "application/gzip", "X-Omarchy-Manifest" => { omarchy_version: "4.1.0" }.to_json)
    assert_response :created, response.body
    bundle = response.parsed_body["bundle"]
    assert_equal 2, bundle["file_count"]
    assert_equal "plain", bundle["encryption"]
    assert_equal "xps-14", bundle["device"]
    assert_equal "4.1.0", bundle["omarchy_version"]
    assert_equal [ ".config/hypr/bindings.lua", ".config/omarchy/shell.json" ], bundle["paths"]
    assert_equal Digest::SHA256.hexdigest(bytes), bundle["sha256"]
    assert bundle["download_url"].start_with?("http://my.test/api/v1/my/dotfiles/")

    get "/api/v1/my/dotfiles", headers: bearer(@token)
    assert_response :success
    assert_equal 1, response.parsed_body["bundles"].size
    assert_nil response.parsed_body["bundles"].first["paths"], "listing is compact"

    get "/api/v1/my/dotfiles/#{bundle['id']}", headers: bearer(@token)
    assert_equal bundle["paths"], response.parsed_body.dig("bundle", "paths")

    get "/api/v1/my/dotfiles/#{bundle['id']}/download", headers: bearer(@token)
    assert_response :success
    assert_equal bytes, response.body
    assert_equal bundle["sha256"], response.headers["X-Omarchy-Sha256"]
    assert_equal "plain", response.headers["X-Omarchy-Encryption"]
  end

  test "the listing comes from the archive, never from the client's claim" do
    post "/api/v1/my/dotfiles", params: dotfile_bundle_bytes, headers: bearer(@token,
      "Content-Type" => "application/gzip", "X-Omarchy-Manifest" => { paths: [ "made-up.txt" ] }.to_json)
    assert_response :created
    assert_not_includes response.parsed_body.dig("bundle", "paths"), "made-up.txt"
  end

  test "credentials are refused by path" do
    [ ".ssh/id_ed25519", ".gnupg/private-keys-v1.d/x.key", ".aws/credentials", ".config/omarchy/agents/fireworks.json",
      ".config/foo/server.pem", ".netrc" ].each do |path|
      post "/api/v1/my/dotfiles", params: dotfile_bundle_bytes({ path => "secret" }), headers: bearer(@token, "Content-Type" => "application/gzip")
      assert_response :unprocessable_entity, path
      assert_match(/never synced/, response.parsed_body["error"])
    end
    assert_equal 0, @user.dotfile_bundles.count
  end

  test "tar safety is shared with the plugin pipeline" do
    evil = TarballBuilder.build(manifest: nil, files: { "ok.txt" => "x" }, symlink: { name: "link", target: "/etc/passwd" })
    post "/api/v1/my/dotfiles", params: evil, headers: bearer(@token, "Content-Type" => "application/gzip")
    assert_response :unprocessable_entity
    assert_match(/symlinks/, response.parsed_body["error"])

    escape = TarballBuilder.build(manifest: nil, files: { "../outside" => "x" })
    post "/api/v1/my/dotfiles", params: escape, headers: bearer(@token, "Content-Type" => "application/gzip")
    assert_response :unprocessable_entity
    assert_match(/illegal path/, response.parsed_body["error"])

    post "/api/v1/my/dotfiles", params: "not a tarball", headers: bearer(@token, "Content-Type" => "application/gzip")
    assert_response :unprocessable_entity
  end

  test "encrypted bundles are stored opaque with the declared listing, still screened" do
    bytes = "age-encryption.org/v1\n-> X25519 abc\n" + SecureRandom.random_bytes(200)
    post "/api/v1/my/dotfiles", params: bytes, headers: bearer(@token, "Content-Type" => "application/octet-stream",
      "X-Omarchy-Manifest" => { paths: [ "./.config/omarchy/shell.json", ".config/hypr/monitors.lua" ], omarchy_version: "4.1.0" }.to_json)
    assert_response :created, response.body
    assert_equal "age", response.parsed_body.dig("bundle", "encryption")
    assert_equal [ ".config/hypr/monitors.lua", ".config/omarchy/shell.json" ], response.parsed_body.dig("bundle", "paths")

    post "/api/v1/my/dotfiles", params: bytes, headers: bearer(@token, "Content-Type" => "application/octet-stream",
      "X-Omarchy-Manifest" => { paths: [ ".ssh/config" ] }.to_json)
    assert_response :unprocessable_entity
  end

  test "only the newest snapshots are kept" do
    (DotfileBundle::KEEP_PER_USER + 2).times do |i|
      post "/api/v1/my/dotfiles", params: dotfile_bundle_bytes({ "file-#{i}" => "x" }), headers: bearer(@token, "Content-Type" => "application/gzip")
      assert_response :created
    end
    assert_equal DotfileBundle::KEEP_PER_USER, @user.dotfile_bundles.count
    assert_equal [ "file-#{DotfileBundle::KEEP_PER_USER + 1}" ], @user.dotfile_bundles.newest_first.first.paths
  end

  test "size caps are enforced before buffering" do
    post "/api/v1/my/dotfiles", params: "x", headers: bearer(@token, "Content-Type" => "application/gzip",
      "Content-Length" => (DotfileBundle::MAX_ARCHIVE_BYTES + 1).to_s)
    assert_response :content_too_large
  end

  test "bundles are private to their account" do
    post "/api/v1/my/dotfiles", params: dotfile_bundle_bytes, headers: bearer(@token, "Content-Type" => "application/gzip")
    id = response.parsed_body.dig("bundle", "id")
    other = account_token_for(create_my_user(email: "other@example.com", handle: "other"))
    get "/api/v1/my/dotfiles/#{id}", headers: bearer(other)
    assert_response :not_found
    get "/api/v1/my/dotfiles/#{id}/download", headers: bearer(other)
    assert_response :not_found
  end

  test "web: list, show, download, delete" do
    post "/api/v1/my/dotfiles", params: dotfile_bundle_bytes, headers: bearer(@token, "Content-Type" => "application/gzip")
    bundle = @user.dotfile_bundles.last
    sign_in_as @user
    get my_dotfiles_path
    assert_response :success
    assert_match "xps-14", response.body
    get my_dotfile_path(bundle)
    assert_response :success
    assert_match ".config/omarchy/shell.json", response.body
    get download_my_dotfile_path(bundle)
    assert_response :success
    assert_equal "application/gzip", response.media_type
    delete my_dotfile_path(bundle)
    assert_redirected_to my_dotfiles_path
    assert_equal 0, @user.dotfile_bundles.count
  end
end
