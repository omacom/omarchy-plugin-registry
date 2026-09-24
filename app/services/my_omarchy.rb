# My Omarchy — the account side of the app: a signed-in machine's dotfile
# sync, omasnap share links, and a spend-capped voice-transcription key.
# Lives in the same Rails app as the plugin registry (one account, one
# sign-in, one admin) and answers on its own hostname, my.omarchy.org.
module MyOmarchy
  module_function

  def base_url = Rails.application.config.x.my_omarchy_base_url

  def host = URI(base_url).host

  # True when a request arrived on the My Omarchy hostname AND that hostname
  # is distinct from the registry's — on a single-host deployment (dev, test
  # by default) the paths under /my are the only door, and the registry root
  # keeps the directory.
  def my_host?(request_host)
    request_host.to_s.casecmp?(host) && !host.casecmp?(DataPlane.host)
  end

  def url(path) = "#{base_url}#{path}"

  def voice_model = Rails.application.config.x.voice_model

  def voice_monthly_limit_usd = Rails.application.config.x.voice_monthly_limit_usd

  def voice_key_ttl = Rails.application.config.x.voice_key_ttl

  def voice_max_active_keys = Rails.application.config.x.voice_max_active_keys

  # Voice needs a management key at the provider; without one the feature is
  # simply off (pages say so, the API says so) rather than half-working.
  def voice_enabled? = OpenRouter.client.present?
end
