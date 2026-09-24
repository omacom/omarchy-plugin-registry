class ReportsController < ApplicationController
  rate_limit to: 10, within: 1.hour, only: :create,
    with: -> { redirect_back fallback_location: root_path, alert: "Slow down." }

  # Snaps are looked up by share token — their ids are never public
  REPORTABLE = { "Comment" => Comment, "Plugin" => Plugin, "Snap" => Snap }.freeze

  def create
    klass = REPORTABLE[params[:reportable_type]] or return head :bad_request
    reportable = klass == Snap ? Snap.find_live_by_token(params[:reportable_id]) : klass.find(params[:reportable_id])
    raise ActiveRecord::RecordNotFound if reportable.nil?
    Report.create!(user: Current.user, reportable:, reason: params[:reason].presence || "unspecified")
    redirect_back fallback_location: root_path, notice: "Reported — an admin will take a look."
  end
end
