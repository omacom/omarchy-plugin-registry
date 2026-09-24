require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module OmarchyPluginRegistry
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Static data plane output (synced to object storage/CDN in production)
    config.x.data_plane_root = Rails.root.join("storage/data_plane")
    config.x.registry_base_url = ENV.fetch("REGISTRY_BASE_URL", "https://plugins.omarchy.org")

    # Publish hold window: a delay before a review-clean version goes live.
    # Off by default — the deterministic scan + AI review are the security
    # gates, and per-plugin submission quotas throttle abuse; a bare timer with
    # nothing watching it only delays honest publishes. Re-enable per incident
    # by setting PUBLISH_HOLD_SECONDS (it becomes the trigger surface for
    # automatic anomaly checks if we add them).
    config.x.publish_hold = ENV.fetch("PUBLISH_HOLD_SECONDS", "0").to_i.seconds

    # Shell command for LLM review of submissions (reads JSON on stdin, prints
    # {"verdict":..., "reasons":[...]}). Unset = AI review disabled.
    config.x.ai_review_command = ENV["AI_REVIEW_COMMAND"]

    # First releases quarantine for a human when AI review is off; dev/test
    # opt out so local publishing stays frictionless.
    config.x.skip_first_release_gate = false

    # Static JWKS override for OIDC trusted publishing (tests inject one;
    # production fetches GitHub's and caches it)
    config.x.github_oidc_jwks = nil

    # Injectable raw-file fetcher for seeded-namespace claim proofs (tests stub it)
    config.x.repo_proof_fetcher = nil

    # Injectable GitHub repo-identity lookup for trusted-publishing registration
    config.x.github_repo_lookup = nil

    # Test seam for display-only repo enrichment (stars/releases) — a callable
    # taking "owner/repo" and returning the stats hash.
    config.x.repo_stats_lookup = nil

    # Origin-side download counting (production uses CDN log aggregation instead)
    config.x.count_origin_downloads = true

    # My Omarchy (my.omarchy.org): the account side — dotfile sync, snap
    # sharing, voice keys — served by this same app on its own hostname.
    config.x.my_omarchy_base_url = ENV.fetch("MY_OMARCHY_BASE_URL", "https://my.omarchy.org")
    # Cloud transcription: the OpenRouter management client (nil = resolve from
    # OPENROUTER_MANAGEMENT_KEY / _FILE at runtime; tests inject a fake), the
    # model handed to clients, the per-account monthly spend cap in USD, how
    # long a minted key lives, and how many may be live at once — the last two
    # bound the operator's total liability.
    config.x.open_router_client = nil
    config.x.voice_model = ENV.fetch("VOICE_MODEL", "openai/whisper-1")
    config.x.voice_monthly_limit_usd = ENV.fetch("VOICE_MONTHLY_LIMIT_USD", "5").to_f
    config.x.voice_key_ttl = ENV.fetch("VOICE_KEY_TTL_DAYS", "90").to_i.days
    config.x.voice_max_active_keys = ENV.fetch("VOICE_MAX_ACTIVE_KEYS", "2000").to_i

    # App-side view counting — plugin pages render at the app regardless, so
    # this stays on in every environment (registry:import_view_counts can
    # supplement from edge analytics)
    config.x.count_views = true

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
