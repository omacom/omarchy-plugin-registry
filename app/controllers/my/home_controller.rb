module My
  class HomeController < BaseController
    # The hub is the one page that also greets a signed-out visitor
    allow_unauthenticated_access only: :show
    skip_before_action :require_onboarded, only: :show

    def show
      return render :welcome unless authenticated?
      return redirect_to onboarding_path unless Current.user.onboarded?
      @user = Current.user
      @devices = @user.devices
      @bundles = @user.dotfile_bundles.newest_first.limit(4).to_a
      @latest_bundle = @bundles.first
      @bundle_count = @user.dotfile_bundles.count
      @snaps = @user.snaps.live.newest_first.with_attached_preview.limit(6)
      @snap_count = @user.snaps.live.count
      @voice_key = @user.voice_key
      @voice_enabled = MyOmarchy.voice_enabled?
    end
  end
end
