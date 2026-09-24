module My
  class DevicesController < BaseController
    def index
      @devices = Current.user.devices
      @pending = Current.user.api_tokens.purpose_account.where(revoked_at: nil).where(expires_at: ...Time.current).order(created_at: :desc).limit(5)
    end

    # Disconnecting a device is an account-security action: step-up first.
    before_action :require_recent_second_factor, only: :destroy

    def destroy
      token = Current.user.api_tokens.purpose_account.find(params[:id])
      token.revoke!
      AuditEvent.record!(actor: Current.user, action: "device.disconnect", subject: token,
        metadata: { device: token.device_name })
      redirect_to my_devices_path, notice: "#{token.device_name.presence || 'Device'} disconnected — it will need to sign in again."
    end
  end
end
