module Admin
  class ReportsController < BaseController
    def resolve
      report = Report.find(params[:id])
      hidden = params[:hide] == "1" && (report.reportable.is_a?(Comment) || report.reportable.is_a?(Snap))
      if hidden
        report.reportable.is_a?(Snap) ? report.reportable.hide!(actor: Current.user, reason: report.reason) : report.reportable.hide!(actor: Current.user)
      end
      report.resolve!(Current.user)
      AuditEvent.record!(actor: Current.user, action: hidden ? "report.resolve_hide" : "report.dismiss",
        subject: report, metadata: { reportable: "#{report.reportable_type}##{report.reportable_id}", reason: report.reason })
      redirect_to admin_root_path, notice: "Report resolved."
    end
  end
end
