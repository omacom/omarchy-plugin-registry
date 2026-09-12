require "application_system_test_case"

class PluginDetailSystemTest < ApplicationSystemTestCase
  setup do
    publisher = Publisher.create!(name: "detail-layout", kind: :org)
    @plugin = Plugin.create!(publisher:, name: "aligned-notice", summary: "Detail notice fixture",
      latest_version: "1.5.0", downloads_count: 12, category: "other")
    @plugin.versions.create!(version: "1.5.0", manifest: {}, sha256: "1" * 64,
      size_bytes: 1024, state: :published, published_at: Time.current)
    @plugin.versions.create!(version: "1.4.0", manifest: {}, sha256: "2" * 64,
      size_bytes: 1024, state: :yanked, published_at: 2.days.ago,
      yanked_at: 1.day.ago, yank_reason: "Broke on compose v2")
  end

  test "withdrawn-version notice aligns with the Omarchy bar and clears it at every width" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit plugin_path("detail-layout", @plugin.name)

    assert_text "Withdrawn versions. v1.4.0 was yanked — Broke on compose v2."

    [ 320, 800, 1440 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width:, height: 900, deviceScaleFactor: 1, mobile: false)
      Selenium::WebDriver::Wait.new(timeout: 2).until do
        page.evaluate_script(<<~JS)
          (() => {
            const bar = document.querySelector(".site-bar").getBoundingClientRect()
            const notices = document.querySelector(".plugin-notices").getBoundingClientRect()
            return Math.abs(bar.left - notices.left) < 0.1 && Math.abs(bar.right - notices.right) < 0.1
          })()
        JS
      end
      layout = page.evaluate_script <<~JS
        (() => {
          const bar = document.querySelector(".site-bar").getBoundingClientRect()
          const notices = document.querySelector(".plugin-notices").getBoundingClientRect()
          const notice = document.querySelector(".plugin-notices .notice-banner").getBoundingClientRect()
          return {
            barLeft: bar.left,
            barRight: bar.right,
            barBottom: bar.bottom,
            noticesLeft: notices.left,
            noticesRight: notices.right,
            noticeTop: notice.top,
            noticeLeft: notice.left,
            noticeRight: notice.right,
            overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
          }
        })()
      JS
      assert_in_delta layout["barLeft"], layout["noticesLeft"], 0.1, width
      assert_in_delta layout["barRight"], layout["noticesRight"], 0.1, width
      assert_in_delta layout["noticesLeft"], layout["noticeLeft"], 0.1, width
      assert_in_delta layout["noticesRight"], layout["noticeRight"], 0.1, width
      assert_in_delta 14, layout["noticeTop"] - layout["barBottom"], 0.1, width
      assert_equal 0, layout["overflow"], width
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
