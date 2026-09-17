class CompatibilityReportsController < ApplicationController
  rate_limit to: 20, within: 1.hour, only: :create, by: -> { Current.user.id }, with: -> { head :too_many_requests }
  before_action :load_version
  after_action { response.headers["Cache-Control"] = "no-store" }

  def new
    @selected_release = OmarchyRelease.find_by(version: params[:omarchy_version], build: params[:omarchy_build].to_s)&.id
    assessment = @version.compatibility_assessments.find_by(omarchy_release_id: @selected_release) if @selected_release
    @report = assessment&.compatibility_reports&.find_by(user: Current.user) || CompatibilityReport.new(modified: params[:modified] == "1")
  end

  def create
    release = OmarchyRelease.find(params.expect(:omarchy_release_id))
    assessment = @version.with_lock { @version.compatibility_assessments.find_or_create_by!(omarchy_release: release) }
    assessment.record_report!(user: Current.user,
      attributes: params.expect(compatibility_report: %i[outcome category details modified public_comment]))
    redirect_to compatibility_path(assessment), status: :see_other,
      notice: "Report saved and linked in the package comments. Problem reports alert the publishing team."
  rescue ActiveRecord::RecordInvalid => e
    @report = e.record
    @selected_release = release&.id
    render :new, status: :unprocessable_entity
  end

  private

  def load_version
    raise ActiveRecord::RecordNotFound unless Current.user.verified_at
    @version = PluginVersion.joins(plugin: :publisher).where(state: [ :published, :yanked ])
      .find_by!(publishers: { name: params[:publisher] }, plugins: { name: params[:name] }, version: params[:version])
    raise ActiveRecord::RecordNotFound if params[:sha256].present? && params[:sha256] != @version.sha256
    @releases = OmarchyRelease.order(created_at: :desc).limit(200)
  end
end
