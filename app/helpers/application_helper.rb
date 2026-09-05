module ApplicationHelper
  def package_path(package)
    package.theme? ? theme_path(package.publisher.name, package.name) : plugin_path(package.publisher.name, package.name)
  end

  def package_version_path(package, version)
    package.theme? ? theme_version_path(package.publisher.name, package.name, version) : plugin_version_path(package.publisher.name, package.name, version)
  end

  def render_markdown(text, asset_base: nil)
    return "" if text.blank?
    html = Commonmarker.to_html(text,
      options: { extension: { table: true, strikethrough: true, autolink: true, tasklist: true },
                 render: { unsafe: false } })
    html = rewrite_relative_images(html, asset_base) if asset_base.present?
    html.html_safe
  end

  # A README is written to be read INSIDE its repository, so its screenshots
  # are repo-relative ("preview.png"). Served from a plugin page those resolve
  # against /plugins/<publisher>/ and 404 — every imported README with an
  # inline screenshot rendered as a broken image. Rewrite them onto the exact
  # commit the version was built from: raw.githubusercontent.com content is
  # immutable per sha, so the picture cannot change under a reviewed version.
  #
  # Relative LINKS (./CONTRIBUTING.md) are still broken — a raw URL would
  # serve unrendered markdown, so they need the repo's tree URL instead.
  def rewrite_relative_images(html, base)
    doc = Nokogiri::HTML5.fragment(html)
    doc.css("img[src]").each do |img|
      src = img["src"].to_s.strip
      next if src.blank? || src.start_with?("#") || src.match?(%r{\A(?:[a-z][a-z0-9+.\-]*:|//)}i)
      img["src"] = URI.join(base, src.delete_prefix("./")).to_s
    rescue URI::Error
      next
    end
    doc.to_html
  end

  # The pinned raw-content base for a version's own source, or nil when we
  # have no provenance to pin to (nothing is rewritten then — a wrong guess
  # would point a plugin page at somebody else's repository).
  def readme_asset_base(version)
    repository = version&.provenance&.dig("repository")
    sha = version&.provenance&.dig("sha")
    return nil if repository.blank? || sha.blank?
    "https://raw.githubusercontent.com/#{repository}/#{sha}/"
  end

  def compact_number(number)
    number_to_human(number, format: "%n%u", precision: 3, significant: true,
      units: { thousand: "k", million: "M", billion: "B" }, strip_insignificant_zeros: true)
  end

  # Turns a manifest-provided repository URL into { icon:, label:, url: } for the
  # sidebar Source row, or nil when the value isn't a linkable http(s) URL.
  def source_repo(url)
    uri = URI.parse(url.to_s)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?
    host = uri.host.downcase.delete_prefix("www.")
    icon, label =
      case host
      when "github.com" then [ :github, "GitHub" ]
      when "gitlab.com" then [ :gitlab, "GitLab" ]
      when /\Agitlab\./ then [ :gitlab, host ]
      when "codeberg.org" then [ :link, "Codeberg" ]
      when "bitbucket.org" then [ :link, "Bitbucket" ]
      else [ :link, host ]
      end
    { icon: icon, label: label, url: uri.to_s }
  rescue URI::InvalidURIError
    nil
  end

  # Share cards and JSON payloads both need absolute URLs — a native client
  # reading /plugins/acme/weather.json can't resolve a root-relative path.
  def absolute_url(path)
    return nil if path.blank?
    "#{DataPlane.base_url}#{path}"
  end

  DEFAULT_META_DESCRIPTION = "Browse, install, and publish plugins and themes for Omarchy. Versioned releases, automated scans, and verified downloads.".freeze

  # OpenGraph/Twitter tags with absolute URLs. Pages call this through
  # content_for(:social); the layout falls back to the site-wide card.
  def social_meta(title:, description:, image_path:, url_path:)
    safe_join([
      tag.meta(property: "og:type", content: "website"),
      tag.meta(property: "og:site_name", content: "Omarchy Hub"),
      tag.meta(property: "og:title", content: title),
      tag.meta(property: "og:description", content: description),
      tag.meta(property: "og:url", content: absolute_url(url_path)),
      tag.meta(property: "og:image", content: absolute_url(image_path)),
      tag.meta(property: "og:image:width", content: 1200),
      tag.meta(property: "og:image:height", content: 630),
      tag.meta(name: "twitter:card", content: "summary_large_image"),
      tag.meta(name: "twitter:title", content: title),
      tag.meta(name: "twitter:description", content: description)
    ], "\n")
  end

  # Directory links that keep the current search/sort/filter state — pass only
  # what changes. Page deliberately resets unless overridden: a filter change
  # always lands on its own first page.
  def directory_path(overrides = {})
    root_path({ q: @query.presence, sort: (@sort if @sort != "downloads"),
                category: @category, tag: @tag, package_type: @package_type }.merge(overrides).compact)
  end

  CARD_RECENCY = 14.days

  # "New" for a first release, "Updated" for a fresh version of an existing
  # plugin — driven by the first/last_published_at columns the directory query
  # selects alongside the row.
  def card_activity_badge(plugin)
    first = plugin.try(:first_published_at)
    return if first.blank?
    if Time.zone.parse(first.to_s) > CARD_RECENCY.ago
      tag.span "New", class: "badge badge--ok"
    elsif (last = plugin.try(:last_published_at)).present? && Time.zone.parse(last.to_s) > CARD_RECENCY.ago
      tag.span "Updated", class: "badge"
    end
  end

  def state_badge(state)
    tone = case state.to_s
    when "published", "active" then "badge--ok"
    when "yanked", "rejected", "security_holding" then "badge--danger"
    when "quarantined", "held" then "badge--warning"
    else ""
    end
    tag.span state.to_s.humanize, class: "badge #{tone}"
  end
end
