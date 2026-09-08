require "application_system_test_case"

class EdgeWavesSystemTest < ApplicationSystemTestCase
  setup do
    publisher = Publisher.create!(name: "wave-lab", kind: :org)
    plugin = Plugin.create!(publisher:, name: "ripple", summary: "Pixel field fixture", latest_version: "1.0.0",
      downloads_count: 30, category: "appearance", tags: [ "desktop" ], kinds: [ "theme" ])
    plugin.versions.create!(version: "1.0.0", manifest: {}, sha256: "0" * 64,
      size_bytes: 1024, state: :published, published_at: Time.current)
  end

  test "hero edge waves survive every viewport width and stay quiet across Turbo restoration" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1200, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    [ 1200, 600, 320, 1241, 1440 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width:, height: 900, deviceScaleFactor: 1, mobile: false)
      Selenium::WebDriver::Wait.new(timeout: 2).until do
        page.evaluate_script(<<~JS)
          (() => {
            const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
            return getComputedStyle(document.querySelector(".site-edge-waves")).display !== "none" &&
              controller.cells.length > 0 && controller.visibleCells.length > 0 &&
              controller.canvasTarget.width === document.documentElement.clientWidth
          })()
        JS
      end
    end
    assert_selector "body[data-edge-waves-state='animating'], body[data-edge-waves-state='quiet']"
    assert_equal 6000, page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").intervalValue
    JS
    viewport = page.evaluate_script <<~JS
      (() => {
        const layer = document.querySelector(".site-edge-waves").getBoundingClientRect()
        return { top: layer.top, left: layer.left, width: layer.width, height: layer.height,
          viewportWidth: document.documentElement.clientWidth, viewportHeight: window.innerHeight }
      })()
    JS
    assert_in_delta 0, viewport["top"], 0.1
    assert_in_delta 0, viewport["left"], 0.1
    assert_in_delta viewport["viewportWidth"], viewport["width"], 0.1
    assert_in_delta viewport["viewportHeight"], viewport["height"], 0.1
    assert_equal viewport["viewportWidth"], page.evaluate_script("document.querySelector('.site-edge-waves canvas').width")
    assert_no_selector "footer .motion-control", visible: :all

    toggle = find(".motion-control", visible: :all)
    page.execute_script("arguments[0].click()", toggle)
    assert_selector "body[data-edge-waves-state='paused']"
    assert_selector ".motion-control[aria-pressed='true']", text: "Resume background animation", visible: :all
    assert page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        return controller.frame === null && controller.timer === null && controller.sparkleTimer === null
      })()
    JS
    previous_ink = page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").ink
    JS
    page.execute_script("document.documentElement.style.setProperty('--ansi-02', '#ff0000'); document.dispatchEvent(new CustomEvent('registry:theme-change'))")
    Selenium::WebDriver::Wait.new(timeout: 2).until do
      page.evaluate_script(<<~JS) != previous_ink
        window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").ink
      JS
    end
    page.execute_script("arguments[0].click()", toggle)
    assert_selector "body[data-edge-waves-state='animating']"

    page.execute_script <<~JS
      window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").completeWave()
    JS
    assert_selector "body[data-edge-waves-state='quiet']"

    click_link "governance"
    assert_current_path governance_path
    assert_equal({ "visible" => 0, "stopped" => true, "toggleHidden" => true }, page.evaluate_script(<<~JS))
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        return {
          visible: controller.visibleCells.length,
          stopped: controller.frame === null && controller.timer === null && controller.sparkleTimer === null,
          toggleHidden: document.querySelector(".motion-control").hidden
        }
      })()
    JS
    page.go_back

    assert_current_path root_path
    assert_selector "body[data-edge-waves-state='quiet']"
    sleep 0.1
    assert_no_selector "body[data-edge-waves-state='animating']"
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "pixel field is confined to safe empty spaces inside the hero" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    hero_only = page.evaluate_script <<~JS
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        const hero = document.querySelector(".hero").getBoundingClientRect()
        const heroContentBottom = Math.max(
          document.querySelector(".hero__copy").getBoundingClientRect().bottom,
          document.querySelector(".fetch").getBoundingClientRect().bottom
        )
        const centralRanges = [
          [document.querySelector(".site-bar").getBoundingClientRect().bottom,
            document.querySelector(".hero__command").getBoundingClientRect().top],
          [document.querySelector(".hero__command").getBoundingClientRect().bottom,
            document.querySelector(".hero__wm").getBoundingClientRect().top + 18],
          [heroContentBottom, hero.bottom]
        ]
        const centerCells = controller.visibleCells.filter((cell) => {
          const x = cell.x + cell.size / 2
          return x >= controller.contentLeft && x <= controller.contentRight
        })
        return {
          hasCells: controller.visibleCells.length > 0,
          allInsideHero: controller.visibleCells.every((cell) => {
            const y = cell.y + cell.size / 2
            return y >= hero.top && y <= hero.bottom
          }),
          centralRangesFilled: centralRanges.every(([top, bottom]) => centerCells.some((cell) => {
            const y = cell.y + cell.size / 2
            return y > top && y < bottom
          })),
          wordmarkToFetchFilled: controller.visibleCells.some((cell) => {
            const wordmark = document.querySelector(".hero__wm").getBoundingClientRect()
            const fetch = document.querySelector(".fetch").getBoundingClientRect()
            const x = cell.x + cell.size / 2
            const y = cell.y + cell.size / 2
            return x > wordmark.right && x < fetch.left && y > wordmark.top && y < wordmark.bottom
          })
        }
      })()
    JS
    assert hero_only["hasCells"]
    assert hero_only["allInsideHero"]
    assert hero_only["centralRangesFilled"]
    assert hero_only["wordmarkToFetchFilled"]

    page.execute_script("document.querySelector('.recent-stream__viewport').scrollIntoView({ block: 'center' })")
    sleep 0.1
    assert_equal({ "visible" => 0, "stopped" => true, "toggleHidden" => true }, page.evaluate_script(<<~JS))
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        return {
          visible: controller.visibleCells.length,
          stopped: controller.frame === null && controller.timer === null && controller.sparkleTimer === null,
          toggleHidden: document.querySelector(".motion-control").hidden
        }
      })()
    JS

    page.execute_script("document.querySelector('.statusfoot').scrollIntoView({ block: 'end' })")
    sleep 0.1
    assert_equal 0, page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").visibleCells.length
    JS

    page.execute_script("document.querySelector('.hero').scrollIntoView({ block: 'start' })")
    Selenium::WebDriver::Wait.new(timeout: 2).until do
      page.evaluate_script(<<~JS)
        (() => {
          const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
          return controller.visibleCells.length > 0 && (controller.frame !== null || controller.timer !== null)
        })()
      JS
    end
    assert_selector ".motion-control:not([hidden])", visible: :all
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "edge waves stay static at the narrowest width when reduced motion is requested" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia",
      features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    visit root_path

    assert_selector "body[data-edge-waves-state='reduced']"
    assert_selector ".motion-control[hidden]", visible: :all
    before = page.evaluate_script("document.querySelector('.site-edge-waves canvas').toDataURL()")
    assert page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        return controller.cells.some((cell) => cell.resting) && controller.sparkleTimer === null
      })()
    JS
    sleep 0.15
    after = page.evaluate_script("document.querySelector('.site-edge-waves canvas').toDataURL()")
    assert_equal before, after
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end
end
