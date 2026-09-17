module CompatibilitySetup
  def setup_compatibility
    @owner = User.create!(email_address: "owner@example.test", name: "Owner", verified_at: Time.current,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    @reporter = User.create!(email_address: "reporter@example.test", name: "Reporter", verified_at: Time.current)
    publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher:, user: @owner, role: :owner, founding: true)
    plugin = Plugin.create!(publisher:, name: "weather")
    @version = plugin.versions.create!(version: "1.0.0", state: :published, published_at: Time.current,
      sha256: "a" * 64, size_bytes: 0, manifest: TarballBuilder.manifest)
    @release = OmarchyRelease.create!(version: "4.2.0", apis: { "plugin" => [ 1 ], "theme" => [ 1 ] })
    @assessment = @version.compatibility_assessments.create!(omarchy_release: @release)
  end

  def problem(user = @reporter, modified: false)
    @assessment.record_report!(user:, attributes: { outcome: "problem", category: "activation", details: "Reproduction: selecting the package does not load it.", modified: })
  end
end
