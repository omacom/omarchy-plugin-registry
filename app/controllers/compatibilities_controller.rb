class CompatibilitiesController < ApplicationController
  allow_unauthenticated_access only: :show
  after_action { response.headers["Cache-Control"] = "no-store" }

  def index
    scope = CompatibilityAssessment.joins(plugin_version: :plugin)
    scope = scope.where(plugins: { publisher_id: Current.user.publishers.select(:id) }) unless Current.user.admin?
    @assessments = scope.includes(:omarchy_release, plugin_version: { plugin: :publisher }).order(updated_at: :desc).limit(100)
  end

  def show
    @assessment = CompatibilityAssessment.includes(:omarchy_release, plugin_version: { plugin: :publisher }).find(params[:id])
    @version = @assessment.plugin_version
    authenticated?
    @privileged = Current.user && (Current.user.admin? || Current.user.member_of?(@version.plugin.publisher))
    raise ActiveRecord::RecordNotFound unless @privileged || @version.published? || @version.yanked?
    @evidence = @assessment.entry
    @reports = @assessment.compatibility_reports.order(updated_at: :desc).limit(100) if @privileged
    respond_to do |format|
      format.html
      format.json { render json: @evidence }
    end
  end
end
