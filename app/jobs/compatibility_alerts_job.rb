require "net/smtp"

class CompatibilityAlertsJob < ApplicationJob
  queue_as :default
  retry_on Net::SMTPServerBusy, Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 5
  limits_concurrency to: 1, key: "compatibility_alerts"

  def perform(assessment_id = nil)
    scope = assessment_id ? CompatibilityAssessment.where(id: assessment_id) : CompatibilityAssessment.all
    scope.find_each do |assessment|
      assessment.with_lock do
        counts = assessment.counts
        level = if assessment.decision == "incompatible"
          3
        elsif assessment.status(counts) == "suspected"
          2
        elsif counts.fetch("problem", 0).positive?
          1
        else
          0
        end
        next if level <= assessment.alert_level
        recipients = assessment.plugin_version.plugin.publisher.memberships.accepted.includes(:user).map(&:user)
          .select { |u| u.suspended_at.nil? && u.verified_at.present? }
        next if recipients.empty?
        recipients.each { |user| assessment.compatibility_notifications.create!(user:, level:) }
        assessment.update!(alert_level: level)
      end
    end
    # Durable outbox: retry lost enqueues and mail failures in the sweep.
    CompatibilityNotification.where(sent_at: nil).find_each do |notification|
      notification.with_lock do
        next if notification.sent_at
        user = notification.user
        publisher = notification.compatibility_assessment.plugin_version.plugin.publisher
        if user.suspended_at.nil? && user.member_of?(publisher)
          CompatibilityMailer.alert(notification).deliver_now
        end
        notification.update!(sent_at: Time.current)
      end
    end
  end
end
