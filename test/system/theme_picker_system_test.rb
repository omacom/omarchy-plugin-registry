require "application_system_test_case"

class ThemePickerSystemTest < ApplicationSystemTestCase
  test "theme arrows select adjacent themes and preserve the choice after reload" do
    visit root_path
    page.execute_script("localStorage.setItem('omarchy-site-theme', 'tokyo-night')")
    page.refresh

    find("button[aria-label='Change website theme']").click
    within("[role='dialog'][aria-label='Theme picker']") do
      assert_selector "[data-theme-picker-target='name']", text: "Tokyo Night"
      find("button[aria-label='Next theme']").click
      assert_selector "[data-theme-picker-target='name']", text: "Vantablack"
      find("button[aria-label='Previous theme']").click
      assert_selector "[data-theme-picker-target='name']", text: "Tokyo Night"
      find("button[aria-label='Next theme']").click
      find("[data-theme-picker-target='name']").click
    end

    assert_no_selector "[role='dialog'][aria-label='Theme picker']"
    assert_selector "html[data-theme='vantablack']"
    page.refresh
    assert_selector "html[data-theme='vantablack']"
  end
end
