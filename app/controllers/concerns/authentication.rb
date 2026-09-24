module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      return nil unless cookies.signed[:session_id]
      session = Session.includes(:user).find_by(id: cookies.signed[:session_id])
      return nil if session.nil?
      # Suspension kills live sessions, not just future sign-ins — a suspended
      # admin or publisher must lose their powers immediately. Expired sessions
      # (absolute or idle lifetime) die on first sight.
      if session.user.suspended_at.present? || session.expired?
        session.destroy
        return nil
      end
      # Refresh the idle clock at most hourly to keep writes cheap
      session.touch if session.updated_at < 1.hour.ago
      session
    end

    def request_authentication
      # Only GET destinations can be returned to — replaying a POST as a GET
      # after sign-in would 404/405
      # Relative path only — a stored absolute URL would bake in whatever Host
      # header the request arrived with
      session[:return_to_after_authenticating] = (request.get? || request.head?) ? request.fullpath : nil
      redirect_to new_session_path
    end

    def after_authentication_url
      stored = session.delete(:return_to_after_authenticating).to_s
      # Same-origin relative paths only ("//host" is protocol-relative — reject)
      (stored.start_with?("/") && !stored.start_with?("//")) ? stored : root_url
    end

    def start_new_session_for(user)
      # The cookie session RESETS at every authentication boundary: pending
      # TOTP secrets, WebAuthn challenges, and step-up breadcrumbs from a
      # previous browser occupant must never leak into the new account. Only
      # the validated return path survives.
      return_to = session[:return_to_after_authenticating]
      reset_session
      session[:return_to_after_authenticating] = return_to if return_to.present?
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed[:session_id] = { value: session.id, httponly: true, same_site: :lax,
                                        expires: Session::ABSOLUTE_LIFETIME.from_now,
                                        # Shared across plugins./my. when configured (see production.rb)
                                        **(ENV["SESSION_COOKIE_DOMAIN"].present? ? { domain: ENV["SESSION_COOKIE_DOMAIN"] } : {}) }
      end
    end

    def terminate_session
      Current.session.destroy
      Current.session = nil
      cookies.delete(:session_id, **(ENV["SESSION_COOKIE_DOMAIN"].present? ? { domain: ENV["SESSION_COOKIE_DOMAIN"] } : {}))
      reset_session
    end
end
