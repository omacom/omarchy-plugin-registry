require "test_helper"

class CompatibilityTest < ActiveSupport::TestCase
  include CompatibilitySetup
  setup { setup_compatibility }

  test "one report per account and target, three problems only warn, positives cannot erase a decision" do
    assert_raises(ActiveRecord::RecordNotFound) { @assessment.decide!(actor: @reporter, decision: "incompatible", reason: "Not a creator or moderator") }
    problem
    problem
    assert_equal 1, CompatibilityReport.count
    assert_equal "unknown", @assessment.status
    2.times do |i|
      user = User.create!(email_address: "report#{i}@example.test", verified_at: Time.current)
      problem(user)
    end
    assert_equal "suspected", @assessment.status
    @assessment.decide!(actor: @owner, decision: "incompatible", reason: "Creator reproduced activation failure")
    @assessment.record_report!(user: @reporter, attributes: { outcome: "works", category: "none", details: "" })
    assert_equal "incompatible", @assessment.reload.status
    assert_equal 1, @assessment.revision
    assert_equal "creator", AuditEvent.last.metadata["actor_role"]
    assert_raises(ActiveRecord::RecordNotFound) { @assessment.decide!(actor: @owner, decision: "none", reason: "fixed") }
    @owner.update!(admin: true)
    @assessment.decide!(actor: @owner, decision: "none", reason: "Moderator verified this was an Omarchy configuration issue")
    assert_equal "reported_working", @assessment.status
  end

  test "modified, unverified and suspended copies never affect aggregate evidence" do
    problem(modified: true)
    assert_empty @assessment.counts
    problem
    @reporter.update!(suspended_at: Time.current)
    assert_empty @assessment.counts
    @reporter.update!(suspended_at: nil, verified_at: nil)
    assert_raises(ActiveRecord::RecordNotFound) { problem }
    assert_empty @assessment.counts
  end

  test "release contracts are bounded immutable and prereleases require an exact build" do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @release.update!(build: "changed") }
    invalid = OmarchyRelease.new(version: "4.3.0-rc.1", channel: "candidate", apis: @release.apis)
    assert_not invalid.valid?
    invalid.build = "a" * 40
    assert invalid.valid?
    invalid.apis = { "theme" => [ true ], "plugin" => [ 1 ] }
    assert_not invalid.valid?
  end

  test "manifest syntax and compatibility API are separate and bounded" do
    contract = { "apiVersion" => 1, "minOmarchyVersion" => "4.0.0", "maxOmarchyVersionExclusive" => "5.0.0" }
    assert_empty PackageCompatibility.errors({ "compatibility" => contract })
    [ nil, false, [], { "apiVersion" => true }, contract.merge("typo" => 1), contract.merge("maxOmarchyVersionExclusive" => "3.0.0") ].each do |value|
      assert_not_empty PackageCompatibility.errors({ "compatibility" => value })
    end
    assert_empty PackageCompatibility.errors({})
  end

  test "signed compatibility survives database restore and is independent of revocations" do
    @assessment.decide!(actor: @owner, decision: "incompatible", reason: "Reproduced")
    generator = DataPlane::Regenerate.new
    DataPlane::Compatibility.write(generator)
    bytes = DataPlane.read("compatibility.json")
    assert DataPlane::Signer.verify?(bytes, DataPlane.read("compatibility.json.sig"))
    assert_equal "incompatible", JSON.parse(bytes)["assessments"].first["status"]
    @assessment.update_columns(decision: "none", revision: 0, reason: "")
    assert_raises(DataPlane::Compatibility::ContinuityError) { DataPlane::Compatibility.write(DataPlane::Regenerate.new) }
    assert_equal bytes, DataPlane.read("compatibility.json")
    assert_raises(DataPlane::Compatibility::ContinuityError) { DataPlane::Regenerate.all }
    assert DataPlane.read("revocations.json").present?
  end
end
