module Api
  module V1
    module My
      # omasnap's share button: POST the image, get back the link.
      class SnapsController < BaseController
        rate_limit to: 60, within: 1.hour, only: :create, by: -> { current_token&.user_id || request.remote_ip },
          store: RATE_LIMIT_STORE, with: -> { render json: { error: "slow_down" }, status: :too_many_requests }

        def index
          snaps = current_user.snaps.live.newest_first.limit(100)
          render json: { schema_version: 1, snaps: snaps.map { |s| snap_json(s) } }
        end

        # POST /api/v1/my/snaps — body: the image bytes. Content-Type names the
        # format. Headers: X-Omarchy-Title (optional), X-Omarchy-Ttl
        # (1h|1d|7d|30d|never, default never), X-Omarchy-Device.
        def create
          bytes = read_body!(Snap::MAX_IMAGE_BYTES) or return
          snap = MyOmarchy::SnapUpload.new(
            user: current_user, bytes: bytes, content_type: request.content_type,
            title: request.headers["X-Omarchy-Title"], ttl: request.headers["X-Omarchy-Ttl"],
            token: current_token, device_name: request.headers["X-Omarchy-Device"] || current_token.device_name).call
          render json: { schema_version: 1, snap: snap_json(snap) }, status: :created
        end

        def destroy
          snap = current_user.snaps.find_by!(token: params[:id])
          snap.destroy!
          head :no_content
        end

        private

        def snap_json(snap)
          {
            token: snap.token,
            url: MyOmarchy.url(snap_path(snap.token)),
            image_url: MyOmarchy.url(snap_image_path(snap.token)),
            title: snap.title,
            width: snap.width,
            height: snap.height,
            byte_size: snap.byte_size,
            content_type: snap.content_type,
            views: snap.views_count,
            device: snap.device_name,
            expires_at: snap.expires_at&.utc&.iso8601,
            created_at: snap.created_at.utc.iso8601
          }
        end
      end
    end
  end
end
