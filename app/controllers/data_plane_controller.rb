# Serves the static data plane in development and as origin behind the CDN in
# production. Installs read these paths; nothing here touches the database
# except the download counter (which CDN log aggregation replaces at scale).
class DataPlaneController < ActionController::API
  def config = serve("config.json#{sig_suffix}", type: content_type_for_json)
  def all = serve("all.json#{sig_suffix}", type: content_type_for_json)
  def revocations = serve("revocations.json#{sig_suffix}", type: content_type_for_json)
  def compatibility = serve("compatibility.json#{sig_suffix}", type: content_type_for_json)
  def legacy_map = serve("legacy-map.json#{sig_suffix}", type: content_type_for_json)
  def signing_key = serve("signing-key.pub", type: "text/plain")

  # Decoded route params must look exactly like names before they touch a
  # path — %2F, dots, and anything else fails closed here.
  # One naming contract — routing rules can never drift from model validation
  NAME_SEGMENT = NameRules::NAME_FORMAT

  def index_file
    return head :not_found unless params[:publisher].to_s.match?(NAME_SEGMENT) && params[:plugin].to_s.match?(NAME_SEGMENT)
    serve("index/#{params[:publisher]}/#{params[:plugin]}.json#{sig_suffix}", type: content_type_for_json)
  end

  def tarball
    return head :not_found unless params[:publisher].to_s.match?(NAME_SEGMENT) && params[:plugin].to_s.match?(NAME_SEGMENT)
    filename = params[:plugin_file]
    version = filename[/\A#{Regexp.escape(params[:plugin])}-([0-9A-Za-z.\-+]+)\.tar\.gz\z/, 1]
    return head :not_found unless version
    served = serve("dl/#{params[:publisher]}/#{params[:plugin]}/#{filename}",
      type: "application/gzip", disposition: "attachment", filename: filename,
      expires: 1.year, immutable: true)
    # Optional origin counting misses CDN cache hits. Deployments importing CDN
    # logs should disable it to avoid double counting. HEAD probes are not downloads.
    count_download(version) if served && request.get? && Rails.application.config.x.count_origin_downloads
  end

  private

  # Signature bytes are selected by the request PATH alone (.sig routes) —
  # never by query string, which shared caches may ignore when keying
  def sig_suffix = request.path.end_with?(".sig") ? ".sig" : ""

  def content_type_for_json = request.path.end_with?(".sig") ? "text/plain" : "application/json"

  # Returns truthy only when the file was actually sent. Indexes are mutable
  # (short cache); tarballs are frozen bytes and mark themselves immutable.
  # The containment check runs on the CANONICALIZED absolute path — ../
  # segments or encoded separators can never escape the data-plane root.
  def serve(relative_path, type:, disposition: "inline", filename: nil, expires: 60.seconds, immutable: false)
    path = File.expand_path(relative_path, DataPlane.root.to_s)
    unless path.start_with?(DataPlane.root.to_s + File::SEPARATOR) && File.file?(path)
      head :not_found
      return false
    end
    expires_in expires, public: true, **(immutable ? { immutable: true } : {})
    send_file(path, type: type, disposition: disposition, filename: filename)
    true
  end

  def count_download(version_string)
    version = PluginVersion.published.joins(plugin: :publisher).find_by(
      plugins: { name: params[:plugin] }, publishers: { name: params[:publisher] },
      version: version_string
    )
    DailyDownload.record!(version) if version
  end
end
