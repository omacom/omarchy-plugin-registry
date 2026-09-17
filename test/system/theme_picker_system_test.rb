require "application_system_test_case"

class ThemePickerSystemTest < ApplicationSystemTestCase
  setup do
    visit root_path
    page.execute_script("localStorage.setItem('omarchy-site-theme', 'tokyo-night'); localStorage.setItem('omarchy-theme-hint-seen', 'true')")
    page.refresh
  end

  test "theme arrows select adjacent themes and preserve the choice after reload" do
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

  test "keyboard and backdrop dismiss without changing the current theme" do
    find("button[aria-label='Change website theme']").click
    find("[role='dialog'][aria-label='Theme picker']").send_keys(:right)
    assert_selector "[data-theme-picker-target='name']", text: "Vantablack"
    backdrop = find(".omarchy-theme-dismiss")
    box = backdrop.evaluate_script("this.getBoundingClientRect().toJSON()")
    page.driver.browser.action.move_to(backdrop.native, -box["width"] / 2 + 10, -box["height"] / 2 + 10).click.perform
    assert_no_selector "[role='dialog'][aria-label='Theme picker']"
    assert_selector "html[data-theme='tokyo-night']"
    assert_equal "Change website theme", page.evaluate_script("document.activeElement.getAttribute('aria-label')")

    find("body").send_keys("t")
    assert_selector "[data-theme-picker-target='name']", text: "Tokyo Night"
    find("[role='dialog'][aria-label='Theme picker']").send_keys(:escape)
    assert_no_selector "[role='dialog'][aria-label='Theme picker']"
    find("input[name='q']").send_keys("t")
    assert_no_selector "[role='dialog'][aria-label='Theme picker']"
  end

  test "desktop previews preserve their aspect ratio and fit above the label" do
    find("button[aria-label='Change website theme']").click
    image = find(".omarchy-theme-card[aria-hidden='false'] img")
    name = find("[data-theme-picker-target='name']")
    box = image.evaluate_script("this.getBoundingClientRect().toJSON()")
    assert_in_delta 1800.0 / 1012, box["width"] / box["height"], 0.01
    assert_operator box["top"], :>=, 0
    assert_operator box["bottom"], :<=, name.evaluate_script("this.getBoundingClientRect().top")
  end

  test "mobile uses portrait previews and swipes without selecting the theme" do
    original_size = page.current_window.size
    page.current_window.resize_to(390, 844)
    find("body").send_keys("t")
    image = find(".omarchy-theme-card[aria-hidden='false'] img")
    box = image.evaluate_script("this.getBoundingClientRect().toJSON()")
    assert_in_delta 0.8, box["width"] / box["height"], 0.01
    assert_operator box["top"], :>=, 0
    assert_operator box["bottom"], :<=, find("[data-theme-picker-target='name']").evaluate_script("this.getBoundingClientRect().top")

    # Real touch input exercises pointer events plus the synthesized click.
    browser = page.driver.browser
    x = box["x"] + box["width"] / 2
    y = box["y"] + box["height"] / 2
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: x + 70, y: } ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove", touchPoints: [ { x: x - 70, y: } ])
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    assert_selector "[data-theme-picker-target='name']", text: "Vantablack"
    assert_selector "html[data-theme='tokyo-night']"
    find("[data-theme-picker-target='name']").click
    assert_no_selector "[role='dialog'][aria-label='Theme picker']"
    assert_selector "html[data-theme='vantablack']"
  ensure
    page.current_window.resize_to(*original_size) if original_size
  end
end
