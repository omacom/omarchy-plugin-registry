require "application_system_test_case"

class RadioSystemTest < ApplicationSystemTestCase
  test "centered radio types its label and supports stop mute wheel volume and progress" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    radio = find(".nav__radio")
    track = find(".nav__radio-track")
    volume = find(".nav__radio-volume-button")
    assert_match(/Play Omarchy radio.*Kevin Koontz/, track["aria-label"])
    assert_equal "false", track["aria-pressed"]
    assert_match(/volume 70 percent/, volume["aria-label"])
    assert_selector ".nav__radio-typed", text: "Kevin Koontz — We Can Fix Everything"
    assert_no_selector ".nav__radio-skip, .nav__radio-time, .nav__radio-meter", visible: :all

    page.execute_script <<~JS
      window.testMediaActions = {}
      navigator.mediaSession.setActionHandler = (action, handler) => { window.testMediaActions[action] = handler }
      Object.defineProperty(HTMLMediaElement.prototype, "duration", { configurable: true, get() { return 245 } })
      Object.defineProperty(HTMLMediaElement.prototype, "currentTime", {
        configurable: true,
        get() { return this.dataset.testTime ? Number(this.dataset.testTime) : 0 },
        set(value) { this.dataset.testTime = String(value) }
      })
      HTMLMediaElement.prototype.play = function() {
        this.dataset.testTime = "61"
        this.dispatchEvent(new Event("playing"))
        this.dispatchEvent(new Event("timeupdate"))
        return Promise.resolve()
      }
    JS
    track.click
    assert_selector ".nav__radio[data-radio-state='playing'] .nav__radio-track[aria-pressed='true']"
    assert_match(/Stop Omarchy radio.*We Can Fix Everything/, track["aria-label"])
    assert_equal [ "pause", "play" ], page.evaluate_script("Object.keys(window.testMediaActions).sort()")
    assert page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector(".nav__radio"), "radio")
        const progress = Number(document.querySelector(".nav__radio-progress").style.transform.match(/[0-9.]+/)[0])
        return controller.typeTimer !== null && progress > 0.24 && progress < 0.26
      })()
    JS
    assert_selector ".nav__radio-cursor", visible: true
    page.execute_script <<~JS
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector(".nav__radio"), "radio")
      controller.stopTypewriter()
      controller.typeCharacter = "Kevin Koontz — We Can Fix Everything".length - 1
      controller.typeNextCharacter()
    JS
    assert_no_selector ".nav__radio-cursor", visible: true
    assert_selector ".nav__radio-typed", text: "Kevin Koontz — We Can Fix Everything"
    assert page.evaluate_script(<<~JS)
      (() => {
        const label = document.querySelector(".nav__radio-typed")
        const track = document.querySelector(".nav__radio-track")
        return label.scrollWidth <= label.clientWidth && label.getBoundingClientRect().right <= track.getBoundingClientRect().right
      })()
    JS

    volume.click
    assert_selector ".nav__radio[data-radio-muted='true'] .nav__radio-volume-button[aria-pressed='true']"
    assert_match(/Unmute.*volume 0 percent/, volume["aria-label"])
    assert_selector ".nav__radio-volume--off", visible: true
    volume.click
    assert_selector ".nav__radio[data-radio-muted='false'] .nav__radio-volume-button[aria-pressed='false']"
    assert_match(/Mute.*volume 70 percent/, volume["aria-label"])

    wheel_result = page.evaluate_script <<~JS
      (() => {
        const button = document.querySelector(".nav__radio-volume-button")
        const belowThreshold = new WheelEvent("wheel", { deltaY: 10, bubbles: true, cancelable: true })
        button.dispatchEvent(belowThreshold)
        let deliberateTurnsPrevented = true
        for (let index = 0; index < 7; index += 1) {
          const event = new WheelEvent("wheel", { deltaY: 100, bubbles: true, cancelable: true })
          button.dispatchEvent(event)
          deliberateTurnsPrevented &&= event.defaultPrevented
        }
        return { belowThreshold: belowThreshold.defaultPrevented, deliberateTurnsPrevented }
      })()
    JS
    refute wheel_result["belowThreshold"]
    assert wheel_result["deliberateTurnsPrevented"]
    assert_selector ".nav__radio[data-radio-muted='true']"
    assert_match(/volume 0 percent/, volume["aria-label"])

    volume.send_keys(:arrow_up)
    assert_selector ".nav__radio[data-radio-muted='false']"
    assert_match(/volume 10 percent/, volume["aria-label"])

    track.click
    assert_selector ".nav__radio[data-radio-state='stopped'] .nav__radio-track[aria-pressed='false']"
    assert_selector ".nav__radio-typed", text: "Kevin Koontz — We Can Fix Everything"
    assert_no_selector ".nav__radio-cursor", visible: true
    assert radio.visible?

    page.execute_script("window.testMediaActions.play()")
    assert_selector ".nav__radio[data-radio-state='playing']"
    page.execute_script("window.testMediaActions.pause()")
    assert_selector ".nav__radio[data-radio-state='stopped']"

    page.execute_script <<~JS
      window.testRadioPlays = []
      HTMLMediaElement.prototype.play = function() {
        const media = this
        window.testRadioMedia = media
        return new Promise((resolve, reject) => {
          window.testRadioPlays.push({
            resolve() { media.dispatchEvent(new Event("playing")); resolve() },
            reject() { reject(new Error("stale play rejection")) }
          })
        })
      }
      HTMLMediaElement.prototype.pause = function() { this.dispatchEvent(new Event("pause")) }
    JS
    track.click
    assert_selector ".nav__radio[data-radio-state='loading']"
    track.click
    assert_selector ".nav__radio[data-radio-state='stopped']"
    track.click
    assert_selector ".nav__radio[data-radio-state='loading']"
    page.execute_script <<~JS
      window.testRadioMedia.dispatchEvent(new Event("pause"))
      window.testRadioPlays[0].reject()
    JS
    assert_selector ".nav__radio[data-radio-state='loading']"
    page.execute_script("window.testRadioPlays[1].resolve()")
    assert_selector ".nav__radio[data-radio-state='playing']"
    track.click
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "playing radio survives responsive artist-only layout changes" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path

    page.execute_script <<~JS
      window.testResponsivePauses = 0
      HTMLMediaElement.prototype.play = function() {
        this.dispatchEvent(new Event("playing"))
        return Promise.resolve()
      }
      HTMLMediaElement.prototype.pause = function() {
        window.testResponsivePauses += 1
        this.dispatchEvent(new Event("pause"))
      }
    JS
    find(".nav__radio-track").click
    assert_selector ".nav__radio[data-radio-state='playing']"

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1000, height: 900, deviceScaleFactor: 1, mobile: false)
    Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == 1000 }
    page.execute_script <<~JS
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector(".nav__radio"), "radio")
      controller.stopTypewriter()
      controller.typeCharacter = controller.currentMessage().length - 1
      controller.typeNextCharacter()
    JS
    assert_selector ".nav__radio[data-radio-state='playing'] .nav__radio-typed", text: "Kevin Koontz"
    assert_selector ".nav__radio", visible: true
    assert_equal 0, page.evaluate_script("window.testResponsivePauses")

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 900, deviceScaleFactor: 1, mobile: false)
    Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == 390 }
    assert_selector ".nav__radio[data-radio-state='playing'] .nav__radio-typed", text: "Kevin Koontz"
    assert_equal 0, page.evaluate_script("window.testResponsivePauses")
    assert_equal 0, page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == 1440 }
    page.execute_script <<~JS
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector(".nav__radio"), "radio")
      controller.stopTypewriter()
      controller.typeCharacter = controller.currentMessage().length - 1
      controller.typeNextCharacter()
    JS
    assert_selector ".nav__radio[data-radio-state='playing'] .nav__radio-typed", text: "Kevin Koontz — We Can Fix Everything"
    assert_equal 0, page.evaluate_script("window.testResponsivePauses")
    find(".nav__radio-track").click
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "radio controls keep coarse-pointer touch targets" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    visit root_path

    targets = page.evaluate_script <<~JS
      (() => ({
        coarse: matchMedia("(pointer: coarse)").matches,
        trackHeight: document.querySelector(".nav__radio-track").getBoundingClientRect().height,
        volumeWidth: document.querySelector(".nav__radio-volume-button").getBoundingClientRect().width,
        volumeHeight: document.querySelector(".nav__radio-volume-button").getBoundingClientRect().height
      }))()
    JS
    assert targets["coarse"]
    assert_operator targets["trackHeight"], :>=, 44
    assert_operator targets["volumeWidth"], :>=, 44
    assert_operator targets["volumeHeight"], :>=, 44

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    Selenium::WebDriver::Wait.new(timeout: 2).until { page.evaluate_script("window.innerWidth") == 320 }
    narrow = page.evaluate_script <<~JS
      (() => {
        const radio = document.querySelector(".nav__radio").getBoundingClientRect()
        const theme = document.querySelector(".theme-toggle").getBoundingClientRect()
        const account = document.querySelector(".nav__account").getBoundingClientRect()
        const volume = document.querySelector(".nav__radio-volume-button").getBoundingClientRect()
        return {
          radioVisible: getComputedStyle(document.querySelector(".nav__radio")).display !== "none",
          volumeVisible: getComputedStyle(document.querySelector(".nav__radio-volume-button")).display !== "none",
          volumeWidth: volume.width,
          volumeHeight: volume.height,
          separated: radio.right <= theme.left && theme.right <= account.left,
          overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
        }
      })()
    JS
    assert narrow["radioVisible"]
    assert narrow["volumeVisible"]
    assert_operator narrow["volumeWidth"], :>=, 44
    assert_operator narrow["volumeHeight"], :>=, 44
    assert narrow["separated"]
    assert_equal 0, narrow["overflow"]
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
