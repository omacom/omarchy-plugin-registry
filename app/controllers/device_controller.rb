# Browser side of the CLI device flow: enter the code, pick the scope, approve.
class DeviceController < ApplicationController
  before_action :require_recent_second_factor, only: :approve
  before_action :require_no_sensitive_cooldown, only: :approve

  def show
    @user_code = params[:code]
    @authorization = DeviceAuthorization.find_by_user_code(@user_code) if @user_code.present?
    if @user_code.present? && @authorization.nil?
      flash.now[:alert] = "That code isn't valid — it may have expired. Re-run the command and try again."
    end
  end

  def approve
    authorization = DeviceAuthorization.find_by_user_code(params[:code])
    return redirect_to device_path, alert: "That code expired — re-run the command." if authorization.nil?

    if params[:decision] == "deny"
      authorization.deny!(user: Current.user)
      return redirect_to (authorization.purpose_account? ? my_root_path : dashboard_path), notice: "Denied. The CLI has been told no."
    end

    # Account-wide token: it can publish to any namespace this user belongs to
    # (each publish still enforces membership, MFA, cooldowns, and the review
    # pipeline). Tighter scoping lands later.
    begin
      token = authorization.approve!(user: Current.user)
    rescue ActiveRecord::RecordInvalid => e
      return redirect_to dashboard_path, alert: e.record.errors.full_messages.join("; ")
    end
    AuditEvent.record!(actor: Current.user, action: "device.approve", subject: authorization,
      metadata: { scope: token.scope_label, purpose: authorization.purpose })
    if authorization.purpose_account?
      redirect_to my_devices_path, notice: "Connected — #{token.device_name.presence || 'that machine'} is signed in to My Omarchy for 90 days."
    else
      redirect_to dashboard_path, notice: "Approved — your terminal has a publish token for your account. It expires in 7 days."
    end
  end
end
