# The public share page for a snap. No sign-in, no listing, no index — the
# token in the URL is the whole authorization, so the only thing a page
# leaks is what its owner chose to share.
class SnapsController < ApplicationController
  allow_unauthenticated_access
  layout "my"
  before_action :load_snap!

  def show
    @owner = authenticated? && Current.user == @snap.user
    @snap.record_view! unless @owner
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end

  def image
    return head :not_found unless @snap.image.attached?
    serve(@snap.image, @snap.content_type, @snap.filename, disposition: params[:download].present? ? "attachment" : "inline")
  end

  def preview
    return head :not_found unless @snap.preview.attached?
    serve(@snap.preview, "image/webp", "preview-#{@snap.token}.webp")
  end

  private

  def load_snap!
    @snap = Snap.find_live_by_token(params[:token]) or raise ActiveRecord::RecordNotFound
  end

  # Bytes are immutable per token; cache privately (the URL is the secret,
  # a shared cache keyed on it would be a copy someone else could reach).
  def serve(attachment, content_type, filename, disposition: "inline")
    expires_in 1.hour, public: false
    response.headers["X-Robots-Tag"] = "noindex"
    send_data attachment.download, type: content_type, filename: filename, disposition: disposition
  end
end
