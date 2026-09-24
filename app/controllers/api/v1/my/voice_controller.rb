module Api
  module V1
    module My
      # The voice key a machine configures voxtype with. GET returns the
      # current key's secret (a second machine needs the same key); POST
      # rotates; DELETE revokes. Minting requires a recent browser approval —
      # the token alone is enough only to READ an existing key.
      class VoiceController < BaseController
        rate_limit to: 10, within: 1.hour, only: %i[create destroy], by: -> { current_token&.user_id || request.remote_ip },
          store: RATE_LIMIT_STORE, with: -> { render json: { error: "slow_down" }, status: :too_many_requests }

        def show
          return render json: { error: "voice transcription is not enabled on this server" }, status: :not_implemented unless MyOmarchy.voice_enabled?
          key = current_user.voice_key
          return render json: { schema_version: 1, voice: nil, message: "No voice key yet — mint one at #{MyOmarchy.url(my_voice_path)}" } if key.nil?
          render json: { schema_version: 1, voice: voice_json(key, secret: true) }
        end

        def create
          key = MyOmarchy::VoiceKeys.mint!(user: current_user,
            device_name: request.headers["X-Omarchy-Device"] || current_token.device_name)
          render json: { schema_version: 1, voice: voice_json(key, secret: true) }, status: :created
        end

        def destroy
          MyOmarchy::VoiceKeys.revoke_all!(user: current_user)
          head :no_content
        end

        private

        def voice_json(key, secret: false)
          {
            provider: key.provider,
            endpoint: "https://openrouter.ai/api",
            model: MyOmarchy.voice_model,
            api_key: (key.secret if secret),
            monthly_limit_usd: key.monthly_limit_usd.to_f,
            usage_monthly_usd: key.usage_monthly_usd.to_f,
            expires_at: key.expires_at.utc.iso8601,
            voxtype: {
              backend: "remote",
              remote_endpoint: "https://openrouter.ai/api",
              remote_model: MyOmarchy.voice_model,
              env: "VOXTYPE_WHISPER_API_KEY"
            }
          }.compact
        end
      end
    end
  end
end
