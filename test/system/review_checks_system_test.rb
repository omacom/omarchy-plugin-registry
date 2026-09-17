require "application_system_test_case"

class ReviewChecksSystemTest < ApplicationSystemTestCase
  test "review evidence shows model passes and expands actual deterministic results on desktop and mobile" do
    original_size = page.current_window.size
    admin = User.create!(email_address: "reviewer@example.com", admin: true,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    publisher = Publisher.create!(name: "review-fixture", kind: :org)
    Membership.create!(publisher:, user: admin, role: :owner, founding: true)
    Rails.application.config.x.enforce_review_policy = true
    Rails.application.config.x.ai_review_command = AiReviewFixture.command
    version = Registry::PublishVersion.new(user: admin, publisher:, plugin_name: "weather",
      tarball_bytes: TarballBuilder.build(manifest: TarballBuilder.manifest(id: "review-fixture.weather"))).call
    Registry::ReviewJob.perform_now(version)
    assert version.reload.published?

    visit root_path
    page.execute_script("localStorage.setItem('omarchy-site-theme','tokyo-night');localStorage.setItem('omarchy-theme-hint-seen','true')")
    session = admin.sessions.create!(second_factor_verified_at: Time.current)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id], same_site: "Lax")
    visit admin_version_path(version)
    assert_selector "h2", text: "Review checks"
    within("#review-checks") do
      assert_text "fixture-model"
      assert_text "Prompt injection and review manipulation"
      assert_text "Source behavior and security"
      assert_text "Complete source coverage"
      assert_no_text "First release requires"
    end
    page.execute_script("document.querySelector('#review-checks').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/review-checks-desktop.png"))

    page.current_window.resize_to(390, 1000)
    within("#review-checks") do
      find("summary").click
      assert_text "Prompt-injection tripwires"
      assert_text "No matching assets in this archive."
      assert_text /not applicable/i
    end
    page.execute_script("document.querySelector('#review-checks').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/review-checks-mobile.png"))
    assert_not page.evaluate_script("document.documentElement.scrollWidth > innerWidth")
  ensure
    Rails.application.config.x.enforce_review_policy = false
    Rails.application.config.x.ai_review_command = nil
    page.current_window.resize_to(*original_size) if original_size
  end
end
