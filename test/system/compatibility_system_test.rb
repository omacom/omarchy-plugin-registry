require "application_system_test_case"

class CompatibilitySystemTest < ApplicationSystemTestCase
  include CompatibilitySetup
  setup { setup_compatibility }

  test "reporting posts a linked public comment and shows version requirements on desktop and mobile" do
    original_size = page.current_window.size
    release = OmarchyRelease.create!(version: "4.0.4", build: "a" * 40, apis: @release.apis)
    OmarchyRelease.create!(version: "3.8.5", apis: @release.apis)
    @version.update!(manifest: @version.manifest.merge("compatibility" => {
      "apiVersion" => 1, "minOmarchyVersion" => "4.0.0", "maxOmarchyVersionExclusive" => "5.0.0"
    }))
    visit root_path
    page.execute_script("localStorage.setItem('omarchy-site-theme','tokyo-night');localStorage.setItem('omarchy-theme-hint-seen','true')")
    session = @reporter.sessions.create!
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id], same_site: "Lax")
    visit "/plugins/acme/weather"
    within("#compatibility") { click_link "Works for me / report a problem" }
    select release.label, from: "Omarchy version / build"
    select "Report a problem", from: "Result"
    select "Activation / loading", from: "What is affected?"
    fill_in "Public comment (optional)", with: "The menu stays closed after clicking the widget."
    fill_in "Private reproduction details (optional)", with: "PRIVATE test diagnostic data"
    click_button "Save compatibility report"
    assert_text "Report saved and linked in the package comments."
    click_link "Community discussion"
    within("#community") do
      assert_text "Compatibility problem"
      assert_text "Omarchy 4.0.4"
      assert_text "The menu stays closed after clicking the widget."
      assert_no_text "PRIVATE"
    end
    page.save_screenshot(Rails.root.join("tmp/compatibility-comments-desktop.png"))
    page.current_window.resize_to(390, 1000)
    page.execute_script("document.querySelector('#compatibility').scrollIntoView()")
    within("#compatibility") do
      assert_text "Omarchy 4.0.0 up to, but not including, 5.0.0"
      assert_text "1 problem report"
      assert_text "Outside the author's supported range"
    end
    page.save_screenshot(Rails.root.join("tmp/compatibility-mobile.png"))
    assert_not page.evaluate_script("document.documentElement.scrollWidth > innerWidth")
  ensure
    page.current_window.resize_to(*original_size) if original_size
  end
end
