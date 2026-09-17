require "test_helper"

class CompatibilityAlertsJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper
  include CompatibilitySetup
  setup { setup_compatibility }

  test "alerts are grouped by target and escalation with a retryable outbox" do
    problem
    assert_emails(1) { CompatibilityAlertsJob.perform_now(@assessment.id) }
    assert_no_emails { CompatibilityAlertsJob.perform_now }
    problem
    assert_no_emails { CompatibilityAlertsJob.perform_now }
    @assessment.decide!(actor: @owner, decision: "incompatible", reason: "Creator reproduction")
    assert_emails(1) { CompatibilityAlertsJob.perform_now }
    assert_equal 2, CompatibilityNotification.where.not(sent_at: nil).count
    assert_no_emails { CompatibilityAlertsJob.perform_now }
  end

  test "modified reports and removed members are not notified" do
    problem(modified: true)
    assert_no_emails { CompatibilityAlertsJob.perform_now }
    notification = @assessment.compatibility_notifications.create!(user: @owner, level: 1)
    @owner.memberships.destroy_all
    assert_no_emails { CompatibilityAlertsJob.perform_now }
    assert notification.reload.sent_at
  end
end
