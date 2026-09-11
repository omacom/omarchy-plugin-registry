require "test_helper"

class DirectoryPaginationTest < ActionDispatch::IntegrationTest
  PER_PAGE = HomeController::PER_PAGE

  setup do
    @publisher = Publisher.create!(name: "acme", kind: :org)
    # Equal downloads on every plugin: the worst case for OFFSET paging, where
    # only the id tiebreaker keeps the page boundary stable.
    (PER_PAGE + 5).times do |i|
      Plugin.create!(publisher: @publisher, name: "plugin-#{i.to_s.rjust(3, "0")}",
        summary: "Plugin #{i}", latest_version: "1.0.0", downloads_count: 100)
    end
  end

  test "first page shows PER_PAGE plugins and a next link, no prev" do
    get root_path
    assert_response :success
    # The Popular shelf above the grid reuses the same card partial, so scope
    # the count to the directory grid itself.
    assert_select "#directory-grid .plugin-card", count: PER_PAGE
    assert_match "Next →", response.body
    assert_no_match(/← Prev/, response.body)
  end

  test "second page shows the remainder and a prev link, no next" do
    get root_path(page: 2)
    assert_response :success
    assert_select "#directory-grid .plugin-card", count: 5
    assert_match "← Prev", response.body
    assert_no_match(/Next →/, response.body)
  end

  test "pages never overlap or skip under a tied sort" do
    get root_path
    page_one = response.body.scan(/plugin-\d{3}/).uniq
    get root_path(page: 2)
    page_two = response.body.scan(/plugin-\d{3}/).uniq
    assert_empty page_one & page_two
    assert_equal PER_PAGE + 5, (page_one + page_two).uniq.size
  end

  test "pager preserves search and sort" do
    get root_path(q: "plugin", sort: "name")
    assert_response :success
    assert_match "q=plugin", response.body
    assert_match "sort=name", response.body
    assert_match "page=2", response.body
  end

  test "out of range page offers a way back" do
    get root_path(page: 99)
    assert_response :success
    assert_match "Nothing on this page", response.body
  end

  test "no pager when everything fits on one page" do
    Plugin.where(publisher: @publisher).order(:name).limit(6).destroy_all
    get root_path
    assert_response :success
    assert_no_match(/Next →/, response.body)
    assert_no_match(/← Prev/, response.body)
  end
end
