require "test_helper"

class DemoCatalogTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(email_address: "demo-admin@example.com", admin: true)
    @previous_gate = Rails.application.config.x.skip_first_release_gate
    Rails.application.config.x.skip_first_release_gate = false
  end

  teardown do
    Rails.application.config.x.skip_first_release_gate = @previous_gate
  end

  test "demo seeds go through review without manufactured approval or activity" do
    versions = nil
    perform_enqueued_jobs { versions = Registry::DemoCatalog.import(admin: @admin) }
    assert_equal 3, versions.size
    versions.each do |version|
      assert version.reload.quarantined?
      assert_match(/first release/, version.review_notes)
      assert_equal "demo", version.provenance["source"]
      assert_nil version.approved_by_id
      assert_nil version.plugin.latest_version
      assert_empty version.plugin.ratings
      assert version.plugin.summary.include?("Launch demo")
      assert_empty version.scan_results["findings"]
    end
    assert_equal 3, AuditEvent.where(action: "plugin.seed_demo", actor: @admin).count
    assert_no_difference [ "PluginVersion.count", "User.count", "AuditEvent.count" ] do
      assert_equal versions.map(&:id), Registry::DemoCatalog.import(admin: @admin).map(&:id)
    end
  end

  test "seeding cannot conscript a non-admin or take another owner's namespace" do
    assert_raises(ArgumentError) { Registry::DemoCatalog.import(admin: nil) }
    user = User.create!(email_address: "ordinary@example.com")
    assert_raises(ArgumentError) { Registry::DemoCatalog.import(admin: user) }
    Publisher.create!(name: Registry::DemoCatalog::PUBLISHER, kind: :org, allow_reserved: true)
    assert_raises(ArgumentError) { Registry::DemoCatalog.import(admin: @admin) }
    assert_equal 0, PluginVersion.count
  end
end
