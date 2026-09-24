module Admin
  # The human-escalation queue: quarantined/held versions, plus recent activity.
  class DashboardController < BaseController
    def show
      # Held versions are clean and auto-release when the hold expires — only
      # quarantined (human-needed) and processing (pipeline running) surface.
      @queue = PluginVersion.where(state: [ :quarantined, :processing ])
        .includes(plugin: :publisher).order(:created_at)
      @recent_versions = PluginVersion.includes(plugin: :publisher).order(created_at: :desc).limit(20)
      @recent_events = AuditEvent.order(created_at: :desc).includes(:user).limit(30)
      @revocations = Revocation.includes(plugin: :publisher).order(created_at: :desc).limit(10)
      @reports = Report.open.includes(:user, :reportable).order(:created_at)
      @recent_snaps = Snap.live.newest_first.includes(:user).limit(12)
    end
  end
end
