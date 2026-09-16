require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Count downloads at the origin. Immutable tarballs are CDN-cached, so the
  # origin only sees cache misses — this UNDERCOUNTS (repeat installs served
  # from Cloudflare never reach us), but it's a real signal until CDN log
  # aggregation replaces it. Set COUNT_ORIGIN_DOWNLOADS=0 to disable.
  config.x.count_origin_downloads = ENV.fetch("COUNT_ORIGIN_DOWNLOADS", "1") != "0"
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Production must select storage deliberately. Never silently put uploads
  # on the app disk because one R2 setting was omitted. Asset builds need no
  # runtime credentials; explicitly self-hosted installs may select local.
  storage_service = ENV.fetch("ACTIVE_STORAGE_SERVICE", ENV["SECRET_KEY_BASE_DUMMY"].present? ? "local" : "cloudflare")
  raise "ACTIVE_STORAGE_SERVICE must be cloudflare or local" unless %w[cloudflare local].include?(storage_service)
  if storage_service == "cloudflare"
    missing = %w[R2_ENDPOINT R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY].select { |name| ENV[name].blank? }
    raise "Missing production storage settings: #{missing.join(', ')}" if missing.any?
    endpoint = URI.parse(ENV.fetch("R2_ENDPOINT"))
    unless endpoint.is_a?(URI::HTTPS) && endpoint.host && !endpoint.userinfo && !endpoint.query && !endpoint.fragment
      raise "R2_ENDPOINT must be an HTTPS endpoint without credentials, query or fragment"
    end
  end
  config.active_storage.service = storage_service.to_sym

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # Delivery failures must RAISE: the recovery flow starts its 72-hour clock
  # only when the warning email hand-off succeeded, which requires seeing the
  # failure (jobs also retry rather than silently dropping codes).
  config.action_mailer.raise_delivery_errors = true

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: URI(ENV.fetch("REGISTRY_BASE_URL", "https://plugins.omarchy.org")).host }
  if ENV["SMTP_ADDRESS"].present?
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: ENV["SMTP_ADDRESS"],
      port: ENV.fetch("SMTP_PORT", 587).to_i,
      user_name: ENV["SMTP_USERNAME"],
      password: ENV["SMTP_PASSWORD"],
      # Only request SMTP-AUTH when credentials are configured — the mail gem
      # raises if authentication is set with no user name (e.g. Mailpit).
      authentication: (:plain if ENV["SMTP_USERNAME"].present?),
      # TLS required by default — credentials and login codes never travel
      # plaintext over a network. SMTP_STARTTLS=0 exists solely for a mail
      # catcher on the same private docker network (staging Mailpit).
      enable_starttls: ENV.fetch("SMTP_STARTTLS", "1") != "0"
    }.compact
  end

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Host authorization: only the registry host (plus explicitly configured
  # extras) may reach the app. An attacker-pointed domain must never mint or
  # receive publisher/admin session cookies.
  config.hosts = [ ENV.fetch("REGISTRY_HOST", "plugins.omarchy.org") ] +
    ENV.fetch("ADDITIONAL_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
  # Health checks arrive by IP from the load balancer
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
