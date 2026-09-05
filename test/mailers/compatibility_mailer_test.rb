require "test_helper"

class CompatibilityMailerTest < ActionMailer::TestCase
  include CompatibilitySetup
  setup { setup_compatibility }
  test "alert" do
    notification = @assessment.compatibility_notifications.create!(user: @owner, level: 1)
    mail = CompatibilityMailer.alert(notification)
    assert_match "acme/weather@1.0.0 on Omarchy 4.2.0", mail.subject
    assert_equal [ @owner.email_address ], mail.to
    assert_match "#{@assessment.id}", mail.text_part.body.to_s
    assert_match "Review evidence", mail.html_part.body.to_s
  end
end
