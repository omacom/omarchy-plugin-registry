require "test_helper"

class CompatibilityChecksTest < ActiveSupport::TestCase
  include CompatibilitySetup
  setup do
    setup_compatibility
    @owner.update!(admin: true)
    @document = { schemaVersion: 1, target: @release.entry, runner: "disposable-test-vm",
      checks: [ { id: "acme.weather", vers: "1.0.0", sha256: @version.sha256, packageType: "plugin",
        scope: "desktop-activation-v1", status: "failed", summary: "Activation fails on this exact candidate" } ] }
  end

  test "scoped failures warn, infrastructure does not erase them, passes cannot clear confirmed blocks" do
    Registry::RecordCompatibilityChecks.call(actor: @owner, document: @document.to_json)
    assert_equal "suspected", @assessment.reload.status
    @document[:checks][0][:status] = "inconclusive"
    Registry::RecordCompatibilityChecks.call(actor: @owner, document: @document.to_json)
    assert_equal "failed", @assessment.reload.check_result
    @document[:checks][0].merge!(scope: "plugin-manifest-v1", status: "passed")
    Registry::RecordCompatibilityChecks.call(actor: @owner, document: @document.to_json)
    assert_equal "failed", @assessment.reload.check_result
    @assessment.decide!(actor: @owner, decision: "incompatible", reason: "Moderator reproduced failure")
    @document[:checks][0][:scope] = "desktop-activation-v1"
    Registry::RecordCompatibilityChecks.call(actor: @owner, document: @document.to_json)
    assert_equal "passed", @assessment.reload.check_result
    assert_equal "incompatible", @assessment.status
  end

  test "evidence must match exact immutable release and registered candidate contract" do
    private_document = Marshal.load(Marshal.dump(@document))
    private_document[:checks][0][:private_logs] = "Do not publish unknown diagnostic fields"
    assert_raises(ArgumentError) { Registry::RecordCompatibilityChecks.call(actor: @owner, document: private_document.to_json) }
    @document[:checks][0][:sha256] = "b" * 64
    assert_raises(ActiveRecord::RecordNotFound) { Registry::RecordCompatibilityChecks.call(actor: @owner, document: @document.to_json) }
    assert_equal "not_run", @assessment.reload.check_result
    @document[:target]["apis"] = { "theme" => [ 2 ], "plugin" => [ 2 ] }
    assert_raises(ArgumentError) { Registry::RecordCompatibilityChecks.call(actor: @owner, document: @document.to_json) }
    assert_raises(ArgumentError) { Registry::RecordCompatibilityChecks.call(actor: @owner, document: "x" * 100_001) }
    assert_raises(ActiveRecord::RecordNotFound) { Registry::RecordCompatibilityChecks.call(actor: @reporter, document: @document.to_json) }
  end
end
