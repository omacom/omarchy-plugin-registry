module Api
  module V1
    module My
      # The machine side of My Omarchy. Every request carries an ACCOUNT token
      # (oma_…), minted through the device flow with purpose=account. Publish
      # tokens are refused here by construction — authenticate() filters by
      # purpose — so a leaked publish token cannot read dotfiles, and a
      # leaked account token cannot publish a plugin.
      class BaseController < Api::BaseController
        before_action :authenticate_account_token!
        # Nothing here is ever cacheable — it is all per-account
        after_action { response.headers["Cache-Control"] = "no-store" }

        rescue_from MyOmarchy::DotfileSync::Rejected, MyOmarchy::SnapUpload::Rejected do |e|
          render json: { error: e.message }, status: e.status
        end
        rescue_from MyOmarchy::VoiceKeys::Disabled do |e|
          render json: { error: e.message }, status: :not_implemented
        end
        rescue_from MyOmarchy::VoiceKeys::Refused do |e|
          render json: { error: e.message }, status: :forbidden
        end
        rescue_from MyOmarchy::OpenRouter::Error do
          render json: { error: "voice provider unavailable — try again shortly" }, status: :bad_gateway
        end

        private

        def authenticate_account_token!
          raw = request.authorization.to_s[/\ABearer (.+)\z/, 1]
          @current_token = ApiToken.authenticate(raw, purpose: :account)
          return render json: { error: "invalid or expired token" }, status: :unauthorized unless @current_token
          # Suspension is immediate for machines too, not just browsers
          if current_user.suspended_at.present?
            render json: { error: "account suspended" }, status: :forbidden
          end
        end

        def current_user = current_token.user

        # Bounded body read: the declared length is checked, and the read
        # itself is capped so a lying Content-Length can't balloon memory.
        def read_body!(max_bytes)
          if request.content_length.to_i > max_bytes
            render json: { error: "body exceeds #{max_bytes / 1.megabyte}MB limit" }, status: :content_too_large
            return nil
          end
          body = request.body.read(max_bytes + 1) || ""
          if body.bytesize > max_bytes
            render json: { error: "body exceeds #{max_bytes / 1.megabyte}MB limit" }, status: :content_too_large
            return nil
          end
          body
        end
      end
    end
  end
end
