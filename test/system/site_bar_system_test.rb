require "application_system_test_case"

class SiteBarSystemTest < ApplicationSystemTestCase
  test "Omarchy bar follows the content rail and keeps compact sticky rows" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    desktop = page.evaluate_script <<~JS
      (() => {
        const bar = document.querySelector(".site-bar")
        const row = bar.querySelector(".nav")
        const command = document.querySelector(".hero__command")
        const fetch = document.querySelector(".fetch")
        const active = bar.querySelector(".nav__section[aria-current]")
        const barBox = bar.getBoundingClientRect()
        const discovery = document.querySelector(".index-search").getBoundingClientRect()
        return {
          barLeft: barBox.left, barRight: barBox.right,
          contentLeft: command.getBoundingClientRect().left, contentRight: fetch.getBoundingClientRect().right,
          discoveryLeft: discovery.left, discoveryRight: discovery.right,
          rowHeight: row.getBoundingClientRect().height,
          background: getComputedStyle(bar).backgroundColor,
          bodyBackground: getComputedStyle(document.body).backgroundColor,
          activeBackground: getComputedStyle(active).backgroundColor,
          activeRuleHeight: getComputedStyle(active, "::after").height,
          radioCenter: bar.querySelector(".nav__radio").getBoundingClientRect().left +
            bar.querySelector(".nav__radio").getBoundingClientRect().width / 2,
          barCenter: barBox.left + barBox.width / 2,
          barShadow: getComputedStyle(bar).boxShadow,
          markVisible: getComputedStyle(bar.querySelector(".nav__mark")).display !== "none",
          markBands: [...bar.querySelectorAll("#nav-mark-bands stop")]
            .map((stop) => getComputedStyle(stop).stopColor)
        }
      })()
    JS
    assert_in_delta desktop["contentLeft"], desktop["barLeft"], 0.1
    assert_in_delta desktop["contentRight"], desktop["barRight"], 0.1
    assert_operator desktop["discoveryLeft"], :<, desktop["barLeft"]
    assert_operator desktop["discoveryRight"], :>, desktop["barRight"]
    assert_no_selector ".site-bar--wide"
    assert_in_delta 32, desktop["rowHeight"], 0.1
    assert_equal desktop["bodyBackground"], desktop["background"]
    assert_equal "rgba(0, 0, 0, 0)", desktop["activeBackground"]
    assert_equal "1px", desktop["activeRuleHeight"]
    assert_in_delta desktop["barCenter"], desktop["radioCenter"], 0.1
    refute_equal "none", desktop["barShadow"]
    assert desktop["markVisible"]
    assert_equal [
      "rgb(218, 236, 198)", "rgb(218, 236, 198)",
      "rgb(187, 221, 151)", "rgb(187, 221, 151)",
      "rgb(158, 206, 106)", "rgb(158, 206, 106)",
      "rgb(103, 133, 73)", "rgb(103, 133, 73)",
      "rgb(57, 72, 46)", "rgb(57, 72, 46)"
    ], desktop["markBands"]

    page.execute_script("document.documentElement.dataset.theme = 'white'")
    assert_equal "rgb(60, 60, 60)", page.evaluate_script(
      "getComputedStyle(document.querySelector('#nav-mark-bands stop')).stopColor"
    )

    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    assert_selector ".site-bar.site-bar--wide"
    Selenium::WebDriver::Wait.new(timeout: 2).until do
      page.evaluate_script <<~JS
        Math.abs(document.querySelector(".site-bar").getBoundingClientRect().left -
          document.querySelector(".index-search").getBoundingClientRect().left) < 1
      JS
    end
    expanded = page.evaluate_script <<~JS
      (() => {
        const bar = document.querySelector(".site-bar").getBoundingClientRect()
        const discovery = document.querySelector(".index-search").getBoundingClientRect()
        return { top: bar.top, left: bar.left, right: bar.right,
          discoveryLeft: discovery.left, discoveryRight: discovery.right }
      })()
    JS
    assert_in_delta 0, expanded["top"], 0.1
    assert_in_delta expanded["discoveryLeft"], expanded["left"], 0.1
    assert_in_delta expanded["discoveryRight"], expanded["right"], 0.1

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 900, deviceScaleFactor: 1, mobile: false)
    Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == 390 }
    mobile = page.evaluate_script <<~JS
      (() => ({
        rowHeight: document.querySelector(".nav").getBoundingClientRect().height,
        width: document.querySelector(".site-bar").getBoundingClientRect().width,
        viewportWidth: document.documentElement.clientWidth,
        pages: getComputedStyle(document.querySelector(".nav__path")).display,
        radio: getComputedStyle(document.querySelector(".nav__radio")).display,
        radioLabel: document.querySelector(".nav__radio-typed").textContent,
        radioRight: document.querySelector(".nav__radio").getBoundingClientRect().right,
        theme: getComputedStyle(document.querySelector(".theme-toggle")).display,
        themeLeft: document.querySelector(".theme-toggle").getBoundingClientRect().left,
        themeRight: document.querySelector(".theme-toggle").getBoundingClientRect().right,
        account: getComputedStyle(document.querySelector(".nav__account")).display,
        accountLeft: document.querySelector(".nav__account").getBoundingClientRect().left,
        accountRight: document.querySelector(".nav__account").getBoundingClientRect().right,
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      }))()
    JS
    assert_in_delta 44, mobile["rowHeight"], 0.1
    assert_in_delta mobile["viewportWidth"] - 32, mobile["width"], 0.1
    assert_equal "none", mobile["pages"]
    refute_equal "none", mobile["radio"]
    assert_equal "Kevin Koontz", mobile["radioLabel"]
    refute_equal "none", mobile["theme"]
    refute_equal "none", mobile["account"]
    assert_operator mobile["radioRight"], :<=, mobile["themeLeft"]
    assert_operator mobile["themeRight"], :<=, mobile["accountLeft"]
    assert_operator mobile["accountRight"], :<=, mobile["width"] + 16
    assert_equal 0, mobile["overflow"]

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == 320 }
    narrow = page.evaluate_script <<~JS
      (() => ({
        label: document.querySelector(".nav__radio-typed").textContent,
        radioVisible: getComputedStyle(document.querySelector(".nav__radio")).display !== "none",
        volumeVisible: getComputedStyle(document.querySelector(".nav__radio-volume-button")).display !== "none",
        themeWidth: document.querySelector(".theme-toggle").getBoundingClientRect().width,
        accountWidth: document.querySelector(".nav__account").getBoundingClientRect().width,
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      }))()
    JS
    assert_equal "Kevin Koontz", narrow["label"]
    assert narrow["radioVisible"]
    assert narrow["volumeVisible"]
    assert_in_delta 44, narrow["themeWidth"], 0.1
    assert_in_delta 44, narrow["accountWidth"], 0.1
    assert_equal 0, narrow["overflow"]
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "desktop radio reserves clear space beside long navigation controls" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1131, height: 800, deviceScaleFactor: 1, mobile: false)
    visit root_path

    spacing = page.evaluate_script <<~JS
      (() => {
        const path = document.querySelector(".nav__path")
        const admin = document.createElement("a")
        admin.className = "nav__section"
        admin.textContent = "admin"
        path.append(admin)
        document.querySelector(".theme-toggle__label").textContent = "theme=an-extraordinarily-long-system-theme"

        const radio = document.querySelector(".nav__radio").getBoundingClientRect()
        const left = admin.getBoundingClientRect()
        const right = document.querySelector(".theme-toggle").getBoundingClientRect()
        return {
          visible: getComputedStyle(document.querySelector(".nav__radio")).display !== "none",
          trackWidth: document.querySelector(".nav__radio-track").getBoundingClientRect().width,
          leftGap: radio.left - left.right,
          rightGap: right.left - radio.right,
          overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
        }
      })()
    JS

    assert spacing["visible"]
    assert_in_delta 268, spacing["trackWidth"], 0.1
    assert_operator spacing["leftGap"], :>=, 0
    assert_operator spacing["rightGap"], :>=, 0
    assert_equal 0, spacing["overflow"]
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "compact radio stays clear of signed-in account and long system-theme controls" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 500, height: 800, deviceScaleFactor: 1, mobile: false)
    visit root_path

    [ 500, 412 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width:, height: 800, deviceScaleFactor: 1, mobile: false)
      Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == width }
      layout = page.evaluate_script <<~JS
        (() => {
          const account = document.querySelector(".nav__account")
          account.classList.remove("nav__account--sign-in")
          account.classList.add("nav__account--signed-in")
          account.textContent = "account/dashboard →"
          document.querySelector(".theme-toggle__mobile-label").textContent = "system/an-extraordinarily-long-theme"
          const home = document.querySelector(".nav__home").getBoundingClientRect()
          const radio = document.querySelector(".nav__radio").getBoundingClientRect()
          const theme = document.querySelector(".theme-toggle").getBoundingClientRect()
          const accountBox = account.getBoundingClientRect()
          return {
            separated: home.right <= radio.left && radio.right <= theme.left && theme.right <= accountBox.left,
            accountLabel: getComputedStyle(account, "::before").content,
            overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
          }
        })()
      JS
      assert layout["separated"], "expected separated controls at #{width}px"
      assert_equal '"acct"', layout["accountLabel"]
      assert_equal 0, layout["overflow"]
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
