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

    [ 1200, 600, 320, 1241, 1440, 2100 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width:, height: 900, deviceScaleFactor: 1, mobile: false)
      Selenium::WebDriver::Wait.new(timeout: 2).until do
        page.evaluate_script(<<~JS)
          (() => {
            const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
            const blockers = [".hero__command", ".hero__wm", ".hero__lede", ".promptline", ".fetch"]
              .map((selector) => document.querySelector(selector).getBoundingClientRect())
              .filter((area) => area.width && area.height)
            const clearsContent = controller.visibleCells.every((cell) =>
              blockers.every((area) => !(cell.x < area.right && cell.x + cell.size > area.left &&
                cell.y < area.bottom && cell.y + cell.size > area.top)))
            const bounds = (selector) => document.querySelector(selector).getBoundingClientRect()
            const bar = bounds(".site-bar")
            const hero = bounds(".hero")
            const command = bounds(".hero__command")
            const wordmark = bounds(".hero__wm")
            const lede = bounds(".hero__lede")
            const prompt = bounds(".promptline")
            const copy = bounds(".hero__copy")
            const fetch = bounds(".fetch")
            const hasCellIn = (left, right, top, bottom) => controller.visibleCells.some((cell) =>
              cell.x >= left && cell.x + cell.size <= right &&
              cell.y >= top && cell.y + cell.size <= bottom)
            const topFilled = hasCellIn(controller.contentLeft, controller.contentRight,
              bar.bottom, Math.min(command.top, fetch.top))
            const commandGapFilled = hasCellIn(
              Math.max(controller.contentLeft, copy.left), Math.min(controller.contentRight, copy.right),
              command.bottom, wordmark.top)
            const bottomFilled = hasCellIn(controller.contentLeft, controller.contentRight,
              Math.max(copy.bottom, fetch.bottom), hero.bottom)
            const copyRight = Math.max(command.right, wordmark.right, lede.right,
              prompt.width ? prompt.right : 0)
            const middleFilled = copy.bottom < fetch.top
              ? hasCellIn(controller.contentLeft, controller.contentRight, copy.bottom, fetch.top)
              : hasCellIn(copyRight, fetch.left, Math.min(command.top, fetch.top),
                  Math.max(prompt.bottom, fetch.bottom))
            return getComputedStyle(document.querySelector(".site-edge-waves")).display !== "none" &&
              controller.cells.length > 0 && controller.visibleCells.length > 0 &&
              clearsContent && topFilled && commandGapFilled && middleFilled && bottomFilled &&
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
    assert_selector ".motion-control[aria-pressed='true'][aria-label='Resume background animation']", visible: :all
    assert_selector ".motion-control[aria-pressed='true'] .motion-control__play", visible: true
    assert_no_selector ".motion-control[aria-pressed='true'] .motion-control__pause", visible: true
    assert_equal 0, page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        const pixels = controller.canvasContext.getImageData(
          0, 0, controller.canvasTarget.width, controller.canvasTarget.height
        ).data
        let visible = 0
        for (let index = 3; index < pixels.length; index += 4) {
          if (pixels[index] > 0) visible += 1
        }
        return visible
      })()
    JS
    assert page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        return controller.frame === null && controller.timer === null && controller.sparkleTimer === null
      })()
    JS
    assert_equal({ "visibility" => "paused", "layout" => "paused" }, page.evaluate_script(<<~JS))
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        controller.setState("quiet")
        controller.onVisibilityChange()
        const visibility = document.body.dataset.edgeWavesState
        controller.setState("quiet")
        controller.layout()
        return { visibility, layout: document.body.dataset.edgeWavesState }
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
    assert_equal "reveal", page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").animationMode
    JS
    Selenium::WebDriver::Wait.new(timeout: 2).until do
      page.evaluate_script(<<~JS) == "wave"
        window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves").animationMode
      JS
    end

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
        const command = document.querySelector(".hero__command").getBoundingClientRect()
        const wordmark = document.querySelector(".hero__wm").getBoundingClientRect()
        const fetch = document.querySelector(".fetch").getBoundingClientRect()
        const copy = document.querySelector(".hero__copy").getBoundingClientRect()
        const bar = document.querySelector(".site-bar").getBoundingClientRect()
        const hasCellIn = (cells, left, right, top, bottom) => cells.some((cell) =>
          cell.x >= left && cell.x + cell.size <= right &&
          cell.y >= top && cell.y + cell.size <= bottom)
        return {
          hasCells: controller.visibleCells.length > 0,
          allInsideHero: controller.visibleCells.every((cell) => {
            const y = cell.y + cell.size / 2
            return y >= hero.top && y <= hero.bottom
          }),
          centralRangesFilled:
            hasCellIn(controller.visibleCells, controller.contentLeft, controller.contentRight,
              bar.bottom, Math.min(command.top, fetch.top)) &&
            hasCellIn(controller.visibleCells, Math.max(controller.contentLeft, copy.left),
              Math.min(controller.contentRight, copy.right), command.bottom, wordmark.top) &&
            hasCellIn(controller.visibleCells, controller.contentLeft, controller.contentRight,
              heroContentBottom, hero.bottom),
          wordmarkToFetchFilled: hasCellIn(controller.visibleCells, wordmark.right, fetch.left,
            wordmark.top, wordmark.bottom)
        }
      })()
    JS
    assert hero_only["hasCells"]
    assert hero_only["allInsideHero"]
    assert hero_only["centralRangesFilled"]
    assert hero_only["wordmarkToFetchFilled"]

    page.execute_script("document.querySelector('.recent-stream__viewport').scrollIntoView({ block: 'center' })")
    sleep 0.1
    assert_equal({ "visible" => 0, "stopped" => true, "toggleHidden" => false }, page.evaluate_script(<<~JS))
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

  test "the first pixel wave builds progressively instead of appearing all at once" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    pixel_counts = page.evaluate_script <<~JS
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        controller.stop()
        controller.fieldRevealed = false
        const countPixels = (progress) => {
          controller.startedAt = 1000
          controller.paint(1000 + progress * 2600)
          cancelAnimationFrame(controller.frame)
          controller.frame = null
          const pixels = controller.canvasContext.getImageData(
            0, 0, controller.canvasTarget.width, controller.canvasTarget.height
          ).data
          let count = 0
          for (let index = 3; index < pixels.length; index += 4) {
            if (pixels[index] > 0) count += 1
          }
          return count
        }
        const counts = [0, 0.08, 0.4, 0.8].map(countPixels)
        controller.fieldRevealed = true
        controller.drawStatic()
        return counts
      })()
    JS

    assert_equal 0, pixel_counts.first
    assert_operator pixel_counts.second, :>, 0
    assert_operator pixel_counts.third, :>, pixel_counts.second
    assert_operator pixel_counts.fourth, :>, pixel_counts.third
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "pointer movement sends matching pixel waves through the hero" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    static_canvas = page.evaluate_script <<~JS
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        controller.stop()
        controller.fieldRevealed = true
        controller.drawStatic()
        controller.setState("quiet")
        return controller.canvasTarget.toDataURL()
      })()
    JS
    page.execute_script <<~JS
      (() => {
        const hero = document.querySelector(".hero")
        const box = hero.getBoundingClientRect()
        for (let index = 0; index < 6; index += 1) {
          hero.dispatchEvent(new PointerEvent("pointermove", {
            bubbles: true,
            pointerType: "mouse",
            clientX: box.left + 30 + index * 54,
            clientY: box.top + box.height * 0.72
          }))
        }
      })()
    JS
    assert_equal({ "wakes" => 6, "mode" => "pointer", "running" => true }, page.evaluate_script(<<~JS))
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        return { wakes: controller.pointerWakes.length, mode: controller.animationMode,
          running: controller.frame !== null }
      })()
    JS
    sleep 0.2
    refute_equal static_canvas, page.evaluate_script("document.querySelector('.site-edge-waves canvas').toDataURL()")
    Selenium::WebDriver::Wait.new(timeout: 2).until do
      page.evaluate_script(<<~JS)
        (() => {
          const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
          return controller.pointerWakes.length === 0 && controller.frame === null
        })()
      JS
    end

    %w[wave].each do |mode|
      resting = page.evaluate_script <<~JS
        (() => {
          const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
          controller.stop()
          controller.fieldRevealed = true
          controller.drawStatic()
          const resting = controller.canvasTarget.toDataURL()
          const cell = controller.visibleCells[0]
          const now = performance.now()
          controller.pointerWakes = [{
            x: cell.x + cell.size / 2,
            y: cell.y + cell.size / 2,
            startedAt: now - 225
          }]
          controller.startedAt = now - 2600
          controller.paint(now)
          return resting
        })()
      JS
      frames = page.evaluate_async_script <<~JS
        const done = arguments[0]
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        const canvases = []
        requestAnimationFrame(() => {
          canvases.push(controller.canvasTarget.toDataURL())
          requestAnimationFrame(() => {
            canvases.push(controller.canvasTarget.toDataURL())
            done({ canvases, mode: controller.animationMode, running: controller.frame !== null })
          })
        })
      JS
      assert frames["canvases"].all? { |canvas| canvas != resting }, mode
      assert_equal "pointer", frames["mode"], mode
      assert frames["running"], mode
    end

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
    assert_equal({ "visibility" => "reduced", "layout" => "reduced" }, page.evaluate_script(<<~JS))
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "edge-waves")
        controller.setState("quiet")
        controller.onVisibilityChange()
        const visibility = document.body.dataset.edgeWavesState
        controller.setState("quiet")
        controller.layout()
        return { visibility, layout: document.body.dataset.edgeWavesState }
      })()
    JS
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
