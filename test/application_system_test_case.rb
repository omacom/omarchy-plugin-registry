require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include ActiveJob::TestHelper
  # Selenium-manager's cached Chrome (no system-wide install needed)
  SELENIUM_CHROME = Dir[File.expand_path("~/.cache/selenium/chrome/linux64/*/chrome")].max

  # WebAuthn needs a DOMAIN origin (IPs are invalid rp_ids)
  Capybara.server_host = "localhost"

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ] do |options|
    options.binary = SELENIUM_CHROME if SELENIUM_CHROME
  end

  def set_test_theme(theme)
    page.execute_script <<~JS, theme
      localStorage.setItem("registry-theme", arguments[0])
      localStorage.setItem("registry-theme-mode", "manual")
      document.documentElement.dataset.theme = arguments[0]
    JS
  end
end
