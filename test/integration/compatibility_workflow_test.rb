require "test_helper"

class CompatibilityWorkflowTest < ActionDispatch::IntegrationTest
  include CompatibilitySetup
  setup { setup_compatibility }

  def report_params
    { publisher: "acme", name: "weather", version: "1.0.0", sha256: @version.sha256,
      omarchy_release_id: @release.id,
      compatibility_report: { outcome: "problem", category: "activation", details: "private <script>bad()</script> reproduction", modified: "0" } }
  end

  test "authenticated bounded reports with private details and a public summary" do
    post compatibility_reports_path, params: report_params
    assert_redirected_to new_session_path
    sign_in_as @reporter
    get new_compatibility_report_path, params: report_params.except(:compatibility_report)
    assert_response :success
    post compatibility_reports_path, params: report_params
    assert_response :see_other
    post compatibility_reports_path, params: report_params
    assert_equal 1, CompatibilityReport.count
    get compatibility_path(@assessment)
    assert_response :success
    assert_no_match "private", response.body
    get compatibility_path(@assessment, format: :json)
    assert_equal 1, response.parsed_body["problems"]
    assert_no_match "reproduction", response.body
    sign_in_as @owner
    get compatibility_path(@assessment)
    assert_select "pre", text: "private <script>bad()</script> reproduction"
    assert_select "script", text: "bad()", count: 0
    assert_equal "no-store", response.headers["Cache-Control"]
    get compatibilities_path
    assert_response :success
  end

  test "invalid targets and details do not write reports" do
    sign_in_as @reporter
    post compatibility_reports_path, params: report_params.merge(sha256: "b" * 64)
    assert_response :not_found
    post compatibility_reports_path, params: report_params.deep_merge(compatibility_report: { details: "" })
    assert_response :unprocessable_entity
    assert_equal 0, CompatibilityReport.count
  end

  test "decisions require authorized fresh MFA and public evidence" do
    params = { compatibility_assessment_id: @assessment.id, decision: { decision: "incompatible", reason: "Creator reproduction" } }
    sign_in_as @owner, second_factor_verified: false
    post compatibility_decisions_path, params: params
    assert_redirected_to step_up_path
    assert_equal "none", @assessment.reload.decision
    sign_in_as @owner
    post compatibility_decisions_path, params: params.deep_merge(decision: { reason: "" })
    assert_response :unprocessable_entity
    post compatibility_decisions_path, params: params
    assert_response :see_other
    assert_equal "incompatible", @assessment.reload.decision
    @owner.update!(sensitive_change_at: Time.current)
    post compatibility_decisions_path, params: params
    assert_response :redirect
    assert_equal 1, @assessment.reload.revision
  end

  test "only moderators register exact release contracts" do
    sign_in_as @owner
    get admin_omarchy_releases_path
    assert_response :not_found
    @owner.update!(admin: true)
    get admin_omarchy_releases_path
    assert_response :success
    post admin_omarchy_releases_path, params: { omarchy_release: { version: "4.3.0-rc.1", build: "sha123", channel: "candidate", apis: { plugin: [ "1" ], theme: [ "1", "2" ] } } }
    assert_response :see_other
    assert_equal [ 1, 2 ], OmarchyRelease.last.apis["theme"]
  end
end
