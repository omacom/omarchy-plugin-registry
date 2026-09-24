module Admin
  # Takedown for a shared screenshot: the page and bytes go dark at once.
  class SnapsController < BaseController
    def hide
      snap = Snap.find(params[:id])
      snap.hide!(actor: Current.user, reason: params[:reason])
      redirect_back fallback_location: admin_root_path, notice: "Snap hidden."
    end
  end
end
