require "application_system_test_case"

class SiteHeaderSystemTest < ApplicationSystemTestCase
  setup do
    @original_size = page.current_window.size
    visit root_path
    page.execute_script("localStorage.setItem('omarchy-site-theme', 'tokyo-night'); localStorage.setItem('omarchy-theme-hint-seen', 'true')")
    page.refresh
  end

  teardown do
    page.current_window.resize_to(*@original_size)
  end

  test "scrolling the directory carries the section surface on the visible bar" do
    page.execute_script("scrollTo(0, 150)")
    assert_selector ".omarchy-bar[data-nav-past-hero]"
    assert_equal "blur(12px)", find(".omarchy-bar").evaluate_script("getComputedStyle(this).backdropFilter")
    assert_equal "none", find("header.omarchy-header").evaluate_script("getComputedStyle(this).backgroundImage")

    page.current_window.resize_to(390, 844)
    assert_selector ".omarchy-brand__wordmark"
    assert_equal "1", find(".omarchy-brand__wordmark").evaluate_script("getComputedStyle(this).opacity")
    # A section boundary should cross inside the bar without letting text leak through.
    page.execute_script("scrollTo(0, document.querySelector('footer').getBoundingClientRect().top + scrollY - 28)")
    assert_selector ".omarchy-bar[style*='linear-gradient']"
    assert_equal "blur(12px)", find(".omarchy-bar").evaluate_script("getComputedStyle(this).backdropFilter")
    find("button[aria-label='Menu']").click
    assert_equal "none", find(".omarchy-bar").evaluate_script("getComputedStyle(this).backgroundImage")
    assert_equal find("#site-menu").evaluate_script("getComputedStyle(this).backgroundColor"),
      find(".omarchy-bar").evaluate_script("getComputedStyle(this).backgroundColor")
    find("button[aria-label='Close menu']").send_keys(:escape)
    assert_no_selector "#site-menu"
    assert_selector ".omarchy-bar[style*='linear-gradient']"
  end

  test "directory navigation and search work after Turbo visits and from other pages" do
    within("nav[aria-label='Main']") { click_link "Themes" }
    assert_current_path themes_path
    assert_selector "nav[aria-label='Main'] a[aria-current='page']", text: "Themes"
    find("body").send_keys([ :control, "k" ])
    assert_selector "#directory-search:focus"
    find("#directory-search").send_keys("ocean")
    assert_no_selector "[role='dialog'][aria-label='Theme picker']"

    visit publishing_path
    find("body").send_keys([ :control, "k" ])
    assert_selector "#directory-search:focus"
    within("nav[aria-label='Main']") { click_link "Plugins" }
    assert_current_path root_path(package_type: "plugin")
    assert_selector "nav[aria-label='Main'] a[aria-current='page']", text: "Plugins"
  end

  test "mobile search closes the sheet and languages can be opened and dismissed" do
    page.current_window.resize_to(390, 844)
    find("button[aria-label='Menu']").click
    within("#site-menu") { click_button "Search plugins and themes" }
    assert_no_selector "#site-menu"
    assert_selector "#directory-search:focus"

    find("button[aria-label='Omarchy languages']").click
    assert_selector "#site-languages a", text: "English"
    assert_equal "https://omarchy.fr/", find("#site-languages a", text: "Français")["href"]
    find("#site-languages a", text: "English").send_keys(:escape)
    assert_no_selector "#site-languages"
    assert_selector "button[aria-label='Omarchy languages']:focus"
    find("button[aria-label='Omarchy languages']").click
    find(".omarchy-bar").click
    assert_no_selector "#site-languages"

    find("button[aria-label='Menu']").click
    page.current_window.resize_to(1280, 800)
    assert_no_selector "#site-menu"
    assert_no_selector "[data-menu-scrim]"
  end
end
