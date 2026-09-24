module Api
  module V1
    module My
      class AccountController < BaseController
        # GET /api/v1/my/whoami — what a freshly logged-in machine asks first
        def show
          user = current_user
          render json: {
            schema_version: 1,
            user: { name: user.name, email_address: user.email_address, handle: user.personal_publisher&.name },
            device: { name: current_token.device_name, token_expires_at: current_token.expires_at.utc.iso8601 },
            features: {
              dotfiles: true,
              snaps: true,
              voice: MyOmarchy.voice_enabled?
            },
            urls: { web: MyOmarchy.base_url }
          }
        end

        # DELETE /api/v1/my/device — `omarchy my logout`: revoke this token
        def destroy
          current_token.revoke!
          head :no_content
        end
      end
    end
  end
end
