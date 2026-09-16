require "test_helper"

class CompatibilityCommentsTest < ActionDispatch::IntegrationTest
  include CompatibilitySetup
  setup { setup_compatibility }

  def params_for(version = @version, **attributes)
    { publisher: version.plugin.publisher.name, name: version.plugin.name, version: version.version,
      omarchy_release_id: @release.id, compatibility_report: { outcome: "problem", category: "activation",
        details: "Private machine information", modified: "0", public_comment: "The widget does not load." }.merge(attributes) }
  end

  test "plugin and theme reports create linked public comments and enqueue author alerts without leaking private details" do
    theme = @version.plugin.publisher.plugins.create!(name: "night", package_type: "theme")
    theme_version = theme.versions.create!(version: "1.0.0", state: :published, published_at: Time.current, sha256: "b" * 64, size_bytes: 0,
      manifest: TarballBuilder.manifest(id: "acme.night", packageType: "theme", kinds: [ "theme" ], entryPoints: { theme: "colors.toml" }))
    [ @version, theme_version ].each do |version|
      sign_in_as @reporter
      assert_difference "Comment.count", 1 do
        assert_enqueued_with(job: CompatibilityAlertsJob) do
          post compatibility_reports_path, params: params_for(version)
        end
      end
      assert_response :see_other
      comment = Comment.last
      assert_equal version.plugin, comment.plugin
      assert_equal @reporter, comment.user
      assert_equal "The widget does not load.", comment.body
      path = version.plugin.theme? ? "/themes/acme/night" : "/plugins/acme/weather"
      delete session_path
      get path
      assert_response :success
      assert_select "#comment-#{comment.id}", text: /Compatibility problem.*v1.0.0.*Omarchy 4.2.0/m
      assert_select "#comment-#{comment.id}", text: /The widget does not load/
      assert_no_match "Private machine information", response.body
      get "#{path}.json"
      assert_equal "4.2.0", response.parsed_body.dig("plugin", "comments", 0, "compatibility", "omarchy_version")
      assert_no_match "Private machine information", response.body
    end
  end

  test "editing a report updates one comment and preserves moderation" do
    sign_in_as @reporter
    post compatibility_reports_path, params: params_for
    comment = Comment.last
    comment.hide!(actor: @owner)
    post compatibility_reports_path, params: params_for(public_comment: "The failure also happens on a clean setup.")
    assert_response :see_other
    assert_equal 1, Comment.where(compatibility_report_id: comment.compatibility_report_id).count
    assert comment.reload.hidden?
    assert_equal "The failure also happens on a clean setup.", comment.body
    get "/plugins/acme/weather.json"
    assert_empty response.parsed_body.dig("plugin", "comments")
  end

  test "private-only reports share a generic outcome and public-only problems are valid" do
    sign_in_as @reporter
    post compatibility_reports_path, params: params_for(public_comment: "")
    assert_response :see_other
    assert_equal "Reports a loading problem.", Comment.last.body
    post compatibility_reports_path, params: params_for(details: "", public_comment: "Fails while opening the menu.")
    assert_response :see_other
    assert_equal "Fails while opening the menu.", Comment.last.body
    assert_equal 1, CompatibilityReport.count
    assert_equal 1, Comment.count
  end

  test "legacy private reports stay private until a new public-comment form is submitted" do
    old = @assessment.compatibility_reports.create!(user: @reporter, outcome: "problem", category: "activation", details: "Historical private text")
    assert_nil old.comment
    @assessment.record_report!(user: @reporter, attributes: { outcome: "problem", details: "Still private" })
    assert_nil old.reload.comment
    @assessment.record_report!(user: @reporter, attributes: { public_comment: "Public summary only" })
    assert_equal "Public summary only", old.reload.comment.body
    assert_equal "Still private", old.details
  end

  test "an existing report prefills only its author's form and survives edits without new public text" do
    sign_in_as @reporter
    post compatibility_reports_path, params: params_for(details: "", public_comment: "The menu stays closed.")
    report = CompatibilityReport.last
    assert report.reload.valid?
    @assessment.record_report!(user: @reporter, attributes: { modified: true })
    assert_equal "The menu stays closed.", report.reload.comment.body
    target = { publisher: "acme", name: "weather", version: "1.0.0", omarchy_version: @release.version }
    get new_compatibility_report_path, params: target
    assert_select "textarea[name='compatibility_report[public_comment]']", text: "The menu stays closed."
    assert_select "input[name='compatibility_report[modified]'][checked]"
    sign_in_as @owner
    get new_compatibility_report_path, params: target
    assert_select "textarea[name='compatibility_report[public_comment]']", text: ""
    assert_select "textarea[name='compatibility_report[details]']", text: ""
  end

  test "oversized and short public comments roll back and script text is escaped" do
    sign_in_as @reporter
    [ "x", "x" * 2001 ].each do |text|
      assert_no_difference [ "CompatibilityReport.count", "Comment.count" ] do
        post compatibility_reports_path, params: params_for(public_comment: text)
        assert_response :unprocessable_entity
      end
    end
    post compatibility_reports_path, params: params_for(public_comment: "<script>alert(1)</script>")
    get "/plugins/acme/weather"
    assert_select ".comment script", count: 0
    assert_select ".comment p", text: "<script>alert(1)</script>"
  end

  test "main package page shows declared range separately from version-specific reports" do
    @version.update!(manifest: @version.manifest.merge("compatibility" => { "apiVersion" => 1, "minOmarchyVersion" => "4.0.4", "maxOmarchyVersionExclusive" => "5.0.0" }))
    OmarchyRelease.create!(version: "3.8.5", apis: @release.apis)
    problem
    get "/plugins/acme/weather"
    assert_response :success
    assert_select "#compatibility", text: /Omarchy 4.0.4 up to, but not including, 5.0.0/
    assert_select "#compatibility li", text: /Omarchy 3.8.5.*Outside the author's supported range/m
    assert_select "#compatibility li", text: /Omarchy 4.2.0.*1 problem report/m
    assert_select "#compatibility", text: /\{"apiVersion"/, count: 0
  end
end
