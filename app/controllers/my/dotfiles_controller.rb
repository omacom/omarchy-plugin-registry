module My
  class DotfilesController < BaseController
    def index
      @bundles = Current.user.dotfile_bundles.newest_first
    end

    def show
      @bundle = Current.user.dotfile_bundles.find(params[:id])
    end

    def download
      bundle = Current.user.dotfile_bundles.find(params[:id])
      return head :not_found unless bundle.archive.attached?
      send_data bundle.archive.download, type: "application/gzip",
        filename: "omarchy-dotfiles-#{bundle.created_at.strftime('%Y%m%d-%H%M%S')}.tar.gz", disposition: "attachment"
    end

    def destroy
      bundle = Current.user.dotfile_bundles.find(params[:id])
      bundle.archive.purge_later if bundle.archive.attached?
      bundle.destroy!
      redirect_to my_dotfiles_path, notice: "Snapshot deleted."
    end
  end
end
