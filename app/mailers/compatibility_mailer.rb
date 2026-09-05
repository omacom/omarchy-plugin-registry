class CompatibilityMailer < ApplicationMailer
  def alert(notification)
    @assessment = notification.compatibility_assessment
    @version = @assessment.plugin_version
    @target = @assessment.omarchy_release
    @evidence = @assessment.entry
    mail to: notification.user.email_address,
      subject: "Compatibility: #{@version.plugin.full_name}@#{@version.version} on Omarchy #{@target.label}"
  end
end
