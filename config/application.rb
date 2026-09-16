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

    # Only our bounded processors decode media. Automatic attachment analysis
    # or previews would re-open uploaded/derived images inside a Rails worker.
    config.active_storage.analyzers = []
    config.active_storage.previewers = []

    # Static data plane output (synced to object storage/CDN in production)
    config.x.data_plane_root = Rails.root.join("storage/data_plane")
    config.x.registry_base_url = ENV.fetch("REGISTRY_BASE_URL", "https://plugins.omarchy.org")

    # Publish hold window: a delay before a review-clean version goes live.
    # Off by default — deterministic scans + complete AI review are security
    # gates, and per-plugin submission quotas throttle abuse; a bare timer with
    # nothing watching it only delays honest publishes. Re-enable per incident
    # by setting PUBLISH_HOLD_SECONDS (it becomes the trigger surface for
    # automatic anomaly checks if we add them).
    config.x.publish_hold = ENV.fetch("PUBLISH_HOLD_SECONDS", "0").to_i.seconds

    # Tool-less LLM review (JSON in/out, including exact-archive coverage).
    # Production accepts only /rails/script/ai_review_adapter, sandboxed.
    # Development/test may use trusted fixture commands. Missing AI blocks automatic publication.
    config.x.ai_review_command = ENV["AI_REVIEW_COMMAND"]

    # Automatic publication requires all checks and complete, archive-bound AI
    # review. Dynamic call sites still require judgment. Only development/test
    # opt out for local fixtures; production has no environment bypass.
    config.x.enforce_review_policy = true

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
