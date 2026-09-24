module My
  class SnapsController < BaseController
    def index
      @snaps = Current.user.snaps.live.newest_first.with_attached_preview
      @retained = Current.user.snaps.live.sum(:byte_size)
    end

    def destroy
      snap = Current.user.snaps.find_by!(token: params[:id])
      snap.destroy!
      redirect_to my_snaps_path, notice: "Snap deleted — the link is dead."
    end
  end
end
