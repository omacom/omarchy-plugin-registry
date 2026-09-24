module Api
  module V1
    module My
      # Push/pull of dotfile bundles. Pushes are whole snapshots; the client
      # decides what goes in (and encrypts if it wants to), the server bounds
      # size and refuses secrets by path either way.
      class DotfilesController < BaseController
        rate_limit to: 30, within: 1.hour, only: :create, by: -> { current_token&.user_id || request.remote_ip },
          store: RATE_LIMIT_STORE, with: -> { render json: { error: "slow_down" }, status: :too_many_requests }

        def index
          bundles = current_user.dotfile_bundles.newest_first.limit(DotfileBundle::KEEP_PER_USER)
          render json: { schema_version: 1, bundles: bundles.map { |b| bundle_json(b) } }
        end

        def show
          bundle = current_user.dotfile_bundles.find(params[:id])
          render json: { schema_version: 1, bundle: bundle_json(bundle, paths: true) }
        end

        # POST /api/v1/my/dotfiles — body: the tar.gz (or an age-encrypted
        # tar.gz). Headers: X-Omarchy-Device (hostname), X-Omarchy-Manifest
        # (JSON: paths + omarchy_version; only consulted for encrypted bundles).
        def create
          bytes = read_body!(DotfileBundle::MAX_ARCHIVE_BYTES) or return
          bundle = MyOmarchy::DotfileSync.new(
            user: current_user, bytes: bytes, token: current_token,
            device_name: request.headers["X-Omarchy-Device"] || current_token.device_name,
            declared_manifest: declared_manifest).call
          render json: { schema_version: 1, bundle: bundle_json(bundle, paths: true) }, status: :created
        end

        def download
          bundle = current_user.dotfile_bundles.find(params[:id])
          return head :not_found unless bundle.archive.attached?
          response.headers["X-Omarchy-Sha256"] = bundle.sha256
          response.headers["X-Omarchy-Encryption"] = bundle.encryption
          send_data bundle.archive.download, type: "application/gzip",
            filename: "dotfiles-#{bundle.id}.tar.gz", disposition: "attachment"
        end

        private

        def declared_manifest
          raw = request.headers["X-Omarchy-Manifest"].to_s
          return nil if raw.blank? || raw.bytesize > 256.kilobytes
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        def bundle_json(bundle, paths: false)
          {
            id: bundle.id,
            created_at: bundle.created_at.utc.iso8601,
            device: bundle.device_name,
            sha256: bundle.sha256,
            size_bytes: bundle.size_bytes,
            file_count: bundle.file_count,
            encryption: bundle.encryption,
            omarchy_version: bundle.omarchy_version,
            download_url: MyOmarchy.url(download_api_v1_my_dotfile_path(bundle)),
            paths: (bundle.paths if paths)
          }.compact
        end
      end
    end
  end
end
