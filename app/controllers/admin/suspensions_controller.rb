module Admin
  # Compromise containment: suspend/unsuspend accounts and publishers.
  # Suspension kills live sessions and revokes usable tokens immediately.
  class SuspensionsController < BaseController
    def suspend_user
      user = User.find_by(email_address: params[:email_address].to_s.strip.downcase)
      return redirect_to admin_root_path, alert: "No account with that email." if user.nil?
      return redirect_to admin_root_path, alert: "You can't suspend yourself." if user == Current.user

      ApplicationRecord.transaction do
        # A recovery started by the attacker must not keep maturing while the
        # account sits locked — containment resets the recovery clock too
        user.update!(suspended_at: Time.current, recovery_requested_at: nil)
        user.sessions.destroy_all
        user.api_tokens.usable.find_each(&:revoke!)
        # Voice keys spend money: pull them at the provider too
        user.voice_keys.active.find_each { |key| MyOmarchy::VoiceKeys.revoke!(key, actor: Current.user) }
        AuditEvent.record!(actor: Current.user, action: "user.suspend", subject: user,
          public: true, metadata: { reason: params[:reason].presence || "unspecified" })
      end
      redirect_to admin_root_path, notice: "#{user.email_address} suspended; sessions destroyed, tokens revoked."
    end

    def unsuspend_user
      user = User.find_by!(email_address: params[:email_address].to_s.strip.downcase)
      # Belt-and-braces: nothing pending may survive into the unsuspended state
      user.update!(suspended_at: nil, recovery_requested_at: nil, sensitive_change_at: Time.current)
      AuditEvent.record!(actor: Current.user, action: "user.unsuspend", subject: user, public: true)
      redirect_to admin_root_path, notice: "#{user.email_address} unsuspended (publish cooldown applies)."
    end

    def suspend_publisher
      publisher = Publisher.find_by(name: params[:name].to_s.strip.downcase)
      return redirect_to admin_root_path, alert: "No publisher by that name." if publisher.nil?

      ApplicationRecord.transaction do
        publisher.update!(suspended_at: Time.current)
        ApiToken.usable.where(publisher:).find_each(&:revoke!)
        AuditEvent.record!(actor: Current.user, action: "publisher.suspend", subject: publisher,
          public: true, metadata: { name: publisher.name, reason: params[:reason].presence || "unspecified" })
      end
      redirect_to admin_root_path, notice: "#{publisher.name} suspended; its scoped tokens are revoked."
    end

    def unsuspend_publisher
      publisher = Publisher.find_by!(name: params[:name].to_s.strip.downcase)
      publisher.update!(suspended_at: nil)
      AuditEvent.record!(actor: Current.user, action: "publisher.unsuspend", subject: publisher,
        public: true, metadata: { name: publisher.name })
      redirect_to admin_root_path, notice: "#{publisher.name} unsuspended."
    end
  end
end
