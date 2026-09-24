module MyOmarchy
  # Daily: refresh spend on live voice keys and make sure anything expired or
  # revoked locally is gone at the provider too (a failed delete at revoke
  # time retries here). Provider outages leave rows untouched.
  class VoiceKeySweepJob < ApplicationJob
    queue_as :default

    def perform
      client = OpenRouter.client or return
      VoiceKey.active.find_each { |key| VoiceKeys.sync_usage!(key) }
      VoiceKey.where(provider_deleted_at: nil)
        .where("revoked_at IS NOT NULL OR expires_at < ?", Time.current).find_each do |key|
        begin
          client.delete_key(key.provider_hash)
        rescue OpenRouter::Error => e
          # Already gone at the provider counts as deleted; anything else retries tomorrow
          next unless e.message.include?("not found")
        end
        key.update!(provider_deleted_at: Time.current, revoked_at: key.revoked_at || Time.current, secret: nil)
      end
    end
  end
end
