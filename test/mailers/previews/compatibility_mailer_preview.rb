# Preview all emails at http://localhost:3000/rails/mailers/compatibility_mailer
class CompatibilityMailerPreview < ActionMailer::Preview
  # Preview this email at http://localhost:3000/rails/mailers/compatibility_mailer/alert
  def alert
    publisher = Publisher.new(name: "acme")
    plugin = Plugin.new(publisher:, name: "night", package_type: "theme")
    version = PluginVersion.new(plugin:, version: "1.0.0", sha256: "a" * 64)
    target = OmarchyRelease.new(version: "4.2.0", build: "pkg-4.2.0-1")
    assessment = CompatibilityAssessment.new(id: 1, plugin_version: version, omarchy_release: target,
      decision: "incompatible", reason: "Creator reproduced an activation issue on this build.")
    notification = CompatibilityNotification.new(compatibility_assessment: assessment,
      user: User.new(email_address: "creator@example.test"), level: 3)
    CompatibilityMailer.alert(notification)
  end
end
