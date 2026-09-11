require "test_helper"

# Category/tag filtering, typed search operators, the sort modes, and the
# New/Updated card badges.
class DirectoryDiscoveryTest < ActionDispatch::IntegrationTest
  setup do
    @acme = Publisher.create!(name: "acme", kind: :org)
    @rival = Publisher.create!(name: "rival", kind: :org)

    @weather = create_published(publisher: @acme, name: "weather", category: "widgets",
      tags: %w[weather bar], summary: "Forecast in the bar", downloads: 500, first_at: 2.months.ago, last_at: 2.months.ago)
    @mixer = create_published(publisher: @acme, name: "mixer", category: "system",
      tags: %w[audio], summary: "Volume control", downloads: 100, first_at: 3.months.ago, last_at: 2.days.ago)
    @fresh = create_published(publisher: @rival, name: "fresh", category: "widgets",
      tags: %w[clock], summary: "Brand new clock", downloads: 5, first_at: 1.day.ago, last_at: 1.day.ago)
  end

  def create_published(publisher:, name:, category:, tags:, summary:, downloads:, first_at:, last_at:)
    plugin = Plugin.create!(publisher:, name:, summary:, latest_version: "1.1.0",
      downloads_count: downloads, category:, tags:, kinds: [ "bar-widget" ])
    plugin.versions.create!(version: "1.0.0", manifest: {}, sha256: "0" * 64, size_bytes: 1,
      state: :published, published_at: first_at)
    plugin.versions.create!(version: "1.1.0", manifest: {}, sha256: "1" * 64, size_bytes: 1,
      state: :published, published_at: last_at)
    plugin
  end

  test "category chip filters the grid and shows counts" do
    get root_path(category: "widgets")
    assert_response :success
    assert_match "weather", response.body
    assert_match "fresh", response.body
    assert_no_match(/mixer/, response.body)
    assert_select ".chip", text: /Widgets\s*2/
  end

  test "tag filter narrows to tagged plugins" do
    get root_path(tag: "audio")
    assert_match "mixer", response.body
    assert_no_match(/weather/, response.body)
  end

  test "typed operators: @publisher, tag:, kind:, category:" do
    get root_path(q: "@rival")
    assert_match "fresh", response.body
    assert_no_match(/weather/, response.body)

    get root_path(q: "tag:bar")
    assert_match "weather", response.body
    assert_no_match(/mixer/, response.body)

    get root_path(q: "category:system")
    assert_match "mixer", response.body
    assert_no_match(/fresh/, response.body)

    get root_path(q: "kind:bar-widget clock")
    assert_match "fresh", response.body
    assert_no_match(/weather/, response.body)
  end

  test "unknown category and tag params are ignored, not errors" do
    get root_path(category: "nonsense", tag: "alsononsense")
    assert_response :success
    assert_match "weather", response.body
  end

  test "updated sort puts the freshest release first" do
    get root_path(sort: "updated")
    body = response.body
    grid = body.index('id="directory-grid"')
    assert grid, "expected the directory grid in the response"
    assert_operator body.index("mixer", grid), :<, body.index("weather", grid)
  end

  test "popular shelf features the most-downloaded plugins" do
    get root_path
    assert_response :success
    assert_select ".showcase[aria-label='Popular plugins']" do |sections|
      texts = sections.map(&:text)
      assert texts.first.include?("weather"), "expected the top-downloaded plugin in the Popular shelf"
    end
    # The shelf only shows on the unfiltered first page.
    get root_path(category: "widgets")
    assert_select ".showcase[aria-label='Popular plugins']", 0
    get root_path(q: "clock")
    assert_select ".showcase[aria-label='Popular plugins']", 0
    get root_path(page: 2)
    assert_select ".showcase[aria-label='Popular plugins']", 0
  end

  test "cards carry New and Updated badges" do
    get root_path
    assert_select "#directory-grid .plugin-card" do |cards|
      texts = cards.map(&:text)
      assert texts.find { |t| t.include?("fresh") }.include?("New")
      assert texts.find { |t| t.include?("mixer") }.include?("Updated")
      assert_not texts.find { |t| t.include?("weather") }.match?(/New|Updated/)
    end
  end

  test "recently added band appears only on the unfiltered first page" do
    get root_path
    assert_select ".recent-band .recent-card", 1 do |cards|
      assert_match(/fresh/, cards.first.text)
    end
    assert_select ".recent-band a[href=?]", root_path(sort: "newest")

    get root_path(category: "widgets")
    assert_select ".recent-band", 0
    get root_path(q: "clock")
    assert_select ".recent-band", 0
  end

  test "detail page links category and tags back to the filtered directory" do
    get plugin_path("acme", "weather")
    assert_select ".page-head__chips a[href=?]", root_path(category: "widgets")
    assert_select ".page-head__chips a[href=?]", root_path(tag: "weather")
  end
end
