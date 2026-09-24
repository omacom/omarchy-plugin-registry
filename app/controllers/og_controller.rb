class OgController < ApplicationController
  allow_unauthenticated_access

  CACHE_TTL = 6.hours

  # /og/:publisher/:name.png — the share card for a plugin page.
  def plugin
    publisher = Publisher.find_by!(name: params[:publisher])
    plugin = publisher.plugins.find_by!(name: params[:name])
    png = Rails.cache.fetch([ "og-card", "plugin", plugin.id ], expires_in: CACHE_TTL) do
      Registry::OgCard.plugin(plugin)
    end
    serve(png)
  end

  # /og/site.png — the default card for pages without a better one.
  def site
    png = Rails.cache.fetch([ "og-card", "site" ], expires_in: CACHE_TTL) do
      Registry::OgCard.site(
        plugins: Plugin.listed.where.not(latest_version: nil).count,
        publishers: Publisher.claimed.count,
        downloads: Plugin.sum(:downloads_count))
    end
    serve(png)
  end

  # /og/s/:token.png — the link card for a shared snap: the preview itself,
  # boxed to the card ratio. Nothing else about the account is on it.
  def snap
    snap = Snap.find_live_by_token(params[:token]) or raise ActiveRecord::RecordNotFound
    return head :not_found unless snap.preview.attached?
    png = Rails.cache.fetch([ "og-card", "snap", snap.id ], expires_in: CACHE_TTL) do
      Registry::OgCard.snap(snap.preview.download)
    end
    response.headers["X-Robots-Tag"] = "noindex"
    serve(png)
  end

  private

  def serve(png)
    expires_in CACHE_TTL, public: true
    send_data png, type: "image/png", disposition: "inline"
  end
end
