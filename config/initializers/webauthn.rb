WebAuthn.configure do |config|
  # Passkeys must work on both hostnames. Origins list both. The relying-party
  # id must be a registrable-domain suffix of every origin, so in production
  # set PASSKEY_RP_ID=omarchy.org and one credential answers plugins. and my.
  # alike. Unset, it falls back to the registry host: passkeys then work only
  # there (my.omarchy.org still signs in with an emailed code). Changing the
  # rp_id later invalidates every enrolled passkey — decide it before launch.
  origins = [ Rails.application.config.x.registry_base_url,
              Rails.application.config.x.my_omarchy_base_url ].uniq
  config.allowed_origins = origins
  config.rp_id = ENV["PASSKEY_RP_ID"].presence || (URI(origins.first).host if origins.size > 1)
  config.rp_name = "omarchy.org"
end
