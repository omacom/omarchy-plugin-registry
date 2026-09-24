module My
  # Minting spends the operator's money, so it sits behind a fresh second
  # factor like every other credential-minting action in the app.
  class VoiceController < BaseController
    before_action :require_recent_second_factor, only: :create
    before_action :require_no_sensitive_cooldown, only: :create

    def show
      @enabled = MyOmarchy.voice_enabled?
      @key = Current.user.voice_key
      MyOmarchy::VoiceKeys.sync_usage!(@key) if @key && (@key.usage_synced_at.nil? || @key.usage_synced_at < 10.minutes.ago)
      @model = MyOmarchy.voice_model
      @limit = MyOmarchy.voice_monthly_limit_usd
    end

    def create
      key = MyOmarchy::VoiceKeys.mint!(user: Current.user)
      # Shown once in the browser, like a publish token; machines fetch it
      # over the API afterwards.
      flash[:minted_voice_key] = key.secret
      redirect_to my_voice_path, notice: "Voice key minted. Run `omarchy my voice setup` on each machine, or copy the key below."
    rescue MyOmarchy::VoiceKeys::Disabled, MyOmarchy::VoiceKeys::Refused => e
      redirect_to my_voice_path, alert: e.message
    rescue MyOmarchy::OpenRouter::Error
      redirect_to my_voice_path, alert: "The transcription provider is unavailable right now — try again shortly."
    end

    def destroy
      MyOmarchy::VoiceKeys.revoke_all!(user: Current.user)
      redirect_to my_voice_path, notice: "Voice key revoked. Machines using it will fall back to local transcription."
    rescue MyOmarchy::OpenRouter::Error
      redirect_to my_voice_path, alert: "Couldn't reach the provider to revoke — try again shortly."
    end
  end
end
