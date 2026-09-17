require "test_helper"

class PackageSectionsTest < ActionDispatch::IntegrationTest
  setup do
    @publisher = Publisher.create!(name: "acme", kind: :org, claimed: true)
    @widget = package("ocean-widget", "plugin", "widgets", 10)
    @theme = package("ocean-theme", "theme", "appearance", 100)
  end

  def package(name, type, category, downloads = 0)
    plugin = @publisher.plugins.create!(name:, package_type: type, category:, tags: [ "quickshell" ],
      summary: "Ocean palette or widget", latest_version: "1.0.0", downloads_count: downloads)
    plugin.versions.create!(version: "1.0.0", state: :published, published_at: 1.day.ago,
      manifest: {}, sha256: "a" * 64, size_bytes: 0)
    plugin
  end

  test "each section scopes its grid shelves counts facets and form" do
    [ [ root_path, "plugin", @theme, "widgets", "appearance", 10 ],
      [ themes_path, "theme", @widget, "appearance", "widgets", 100 ] ].each do |path, type, excluded, category, other_category, downloads|
      get path
      assert_response :success
      assert_select "#directory-grid .plugin-card", count: 1
      assert_select ".showcase .plugin-card", count: 1
      assert_select ".recent-band .recent-card", count: 1
      assert_select "a.plugin-card[href*='#{excluded.name}'], a.recent-card[href*='#{excluded.name}']", count: 0
      assert_select ".hero__stat", text: "1#{type.pluralize}"
      assert_select ".hero__stat", text: "#{downloads}downloads"
      assert_select ".hero__stat span", text: (type == "theme" ? "plugins" : "themes"), count: 0
      assert_select ".chip[href*='category=#{category}']"
      assert_select ".chip[href*='category=#{other_category}']", count: 0
      assert_select "nav[aria-label='Package type']", count: 0
      assert_select "form.directory__bar[action='#{path}']"
      assert_select "input[aria-label='Search #{type.pluralize}']"
      assert_select ".directory__sort a" do |links|
        assert links.all? { |link| URI.parse(link["href"]).path == path }
      end
    end
  end

  test "search category and sorting cannot mix the sections" do
    [ root_path, themes_path ].each do |path|
      expected = path == root_path ? @widget : @theme
      [ { q: "ocean" }, { q: "tag:quickshell" }, { sort: "rating" }, { category: expected.category } ].each do |query|
        get path, params: query
        assert_response :success
        assert_select "#directory-grid .plugin-card", count: 1
        assert_select "#directory-grid .plugin-card[href*='#{expected.name}']"
      end
    end
    get themes_path(q: "no-result")
    assert_select "a[href='#{themes_path}']", text: "clear filters"
    get theme_path("acme", @theme.name)
    assert_select ".page-head__chips a[href=?]", themes_path(category: "appearance")
    assert_select ".page-head__chips a[href=?]", themes_path(tag: "quickshell")
  end

  test "theme pagination stays in its section and does not count plugins" do
    HomeController::PER_PAGE.times { |i| package("extra-theme-#{i}", "theme", "appearance") }
    get themes_path(sort: "name")
    assert_select "#directory-grid .plugin-card", count: HomeController::PER_PAGE
    assert_select ".directory__pager a[href=?]", themes_path(sort: "name", page: 2)
    get themes_path(sort: "name", page: 2)
    assert_select "#directory-grid .plugin-card", count: 1
    assert_select ".plugin-card[href*='ocean-widget']", count: 0
    assert_select ".directory__pager a[href=?]", themes_path(sort: "name")
  end

  test "legacy theme queries redirect to the theme section with filters preserved" do
    get root_path(package_type: "theme", q: "ocean", sort: "name", page: 2)
    assert_redirected_to themes_path(q: "ocean", sort: "name", page: 2)
    get root_path(package_type: "everything")
    assert_select ".plugin-card[href*='ocean-theme']", count: 0
    get themes_path(package_type: "plugin")
    assert_select "#directory-grid .plugin-card[href*='ocean-theme']"
    assert_select ".plugin-card[href*='ocean-widget']", count: 0
  end

  test "JSON sections stay typed while the explicit package catalog supports both" do
    [ [ "/?format=json", "plugin" ], [ "/plugins.json?package_type=theme", "plugin" ],
      [ "/themes.json?package_type=plugin", "theme" ] ].each do |path, type|
      get path
      assert_response :success
      body = response.parsed_body
      %w[packages popular recent].each do |key|
        assert_equal [ type ], body.fetch(key).map { |entry| entry.fetch("package_type") }.uniq
      end
      assert_equal 1, body.dig("page", "total")
      assert_equal 0, body.dig("stats", type == "theme" ? "plugins" : "themes")
    end
    get packages_json_path
    assert_equal %w[plugin theme], response.parsed_body["packages"].map { |entry| entry["package_type"] }.sort
    get packages_json_path(package_type: "theme")
    assert_equal [ "theme" ], response.parsed_body["packages"].map { |entry| entry["package_type"] }
    get root_path(format: :json, package_catalog: true)
    assert_equal [ "plugin" ], response.parsed_body["packages"].map { |entry| entry["package_type"] }
  end

  test "detail and version URLs cannot cross package sections" do
    [ plugin_path("acme", @theme.name), plugin_version_path("acme", @theme.name, "1.0.0"),
      theme_path("acme", @widget.name), theme_version_path("acme", @widget.name, "1.0.0") ].each do |path|
      get path
      assert_response :not_found
    end
  end

  test "publisher pages give plugins and themes separate sections and JSON collections" do
    get publisher_path("acme")
    assert_select "section[aria-label='Plugins'] .plugin-card[href*='ocean-widget']"
    assert_select "section[aria-label='Plugins'] .plugin-card[href*='ocean-theme']", count: 0
    assert_select "section[aria-label='Themes'] .plugin-card[href*='ocean-theme']"
    assert_select "section[aria-label='Themes'] .plugin-card[href*='ocean-widget']", count: 0
    get publisher_path("acme", format: :json)
    assert_equal [ "ocean-widget" ], response.parsed_body["plugins"].map { |entry| entry["name"] }
    assert_equal [ "ocean-theme" ], response.parsed_body["themes"].map { |entry| entry["name"] }
    assert_equal 1, response.parsed_body.dig("publisher", "plugin_count")
    assert_equal 1, response.parsed_body.dig("publisher", "theme_count")
  end
end
