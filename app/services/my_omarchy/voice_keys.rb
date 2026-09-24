module MyOmarchy
  # Mints, rotates, syncs, and revokes a user's voice key at the provider.
  # Every provider call happens here so the row and the provider never
  # silently disagree: a mint that fails at the provider creates no row; a
  # revoke that fails at the provider leaves the row active to retry.
  module VoiceKeys
    class Disabled < StandardError; end
    class Refused < StandardError; end

    module_function

    def enabled? = MyOmarchy.voice_enabled?

    # Rotates: the previous key is deleted at the provider first, then the new
    # one minted. One live key per account, always.
    def mint!(user:, device_name: nil)
      client = OpenRouter.client or raise Disabled, "voice transcription is not enabled on this server"
      raise Refused, "account is suspended" if user.suspended_at.present?
      unless user.verified_at.present?
        raise Refused, "verify your email address before minting a voice key"
      end
      if VoiceKey.active.count >= MyOmarchy.voice_max_active_keys
        raise Refused, "voice keys are at capacity right now — try again later"
      end

      revoke_all!(user: user, client: client)
      expires_at = MyOmarchy.voice_key_ttl.from_now
      minted = client.create_key(name: "my.omarchy.org voice · user #{user.id}",
        limit_usd: MyOmarchy.voice_monthly_limit_usd, expires_at: expires_at)
      key = user.voice_keys.create!(provider: "openrouter", provider_hash: minted.hash,
        label: minted.label, secret: minted.secret, monthly_limit_usd: MyOmarchy.voice_monthly_limit_usd,
        expires_at: expires_at, device_name: ApiToken.sanitize_device_name(device_name))
      AuditEvent.record!(actor: user, action: "voice_key.mint", subject: key,
        metadata: { limit_usd: key.monthly_limit_usd.to_f, expires_at: expires_at.utc.iso8601 })
      key
    rescue ActiveRecord::RecordInvalid => e
      # The provider already holds the key; never leave it live without a row
      client.delete_key(minted.hash) if minted rescue nil
      raise Refused, e.record.errors.full_messages.join("; ")
    end

    def revoke!(key, actor: nil)
      client = OpenRouter.client
      if client && key.provider_deleted_at.nil?
        begin
          client.delete_key(key.provider_hash)
        rescue OpenRouter::Error => e
          # "not found" means already gone at the provider — that IS revoked
          raise unless e.message.include?("not found")
        end
        key.update!(provider_deleted_at: Time.current)
      end
      key.revoke_locally!
      AuditEvent.record!(actor: actor || key.user, action: "voice_key.revoke", subject: key)
      key
    end

    def revoke_all!(user:, client: OpenRouter.client)
      user.voice_keys.active.find_each { |key| revoke!(key) }
    end

    # Pull spend from the provider so the page can show it. Best-effort: a
    # provider hiccup leaves the last synced numbers in place.
    def sync_usage!(key)
      client = OpenRouter.client or return key
      remote = client.get_key(key.provider_hash)
      key.update!(usage_usd: remote.usage, usage_monthly_usd: remote.usage_monthly, usage_synced_at: Time.current)
      key
    rescue OpenRouter::Error
      key
    end
  end
end
