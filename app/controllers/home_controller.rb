class HomeController < ApplicationController
  include ConditionalGet
  allow_unauthenticated_access
  before_action :redirect_legacy_theme_directory

  # Computed per row from the versions table — plugins.updated_at is useless
  # here (any counter or metadata write touches it). The published-state enum
  # integer is bound, not interpolated: a SQL constant assembled by hand is
  # the shape a scanner has to flag, and it costs nothing to bind it.
  PUBLISHED_STATE = PluginVersion.states.fetch(:published)
  LAST_PUBLISHED_SQL = ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, PUBLISHED_STATE ]).freeze
    (SELECT MAX(pv.published_at) FROM plugin_versions pv
      WHERE pv.plugin_id = plugins.id AND pv.state = ?)
  SQL
  FIRST_PUBLISHED_SQL = ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, PUBLISHED_STATE ]).freeze
    (SELECT MIN(pv.published_at) FROM plugin_versions pv
      WHERE pv.plugin_id = plugins.id AND pv.state = ?)
  SQL
  WEEK_DOWNLOADS_SQL = <<~SQL.squish.freeze
    (SELECT COALESCE(SUM(dd.count), 0) FROM daily_downloads dd
      JOIN plugin_versions pv ON pv.id = dd.plugin_version_id
      WHERE pv.plugin_id = plugins.id AND dd.date >= date('now', '-7 days'))
  SQL

  SORTS = {
    "downloads" => "plugins.downloads_count DESC",
    "trending" => "#{WEEK_DOWNLOADS_SQL} DESC",
    "rating" => "CASE WHEN ratings_count = 0 THEN 0 ELSE ratings_sum * 1.0 / ratings_count END DESC, ratings_count DESC",
    "updated" => "#{LAST_PUBLISHED_SQL} DESC NULLS LAST",
    "newest" => "plugins.created_at DESC",
    "name" => "plugins.name ASC"
  }.freeze

  PER_PAGE = 24
  # JSON callers may ask for a larger page so building a local index doesn't
  # take dozens of round trips. Capped: an uncapped page size on a directory
  # heading for six figures is a cheap way to make the server do a lot of work.
  MAX_PER_PAGE = 100

  def index
    # Website sections are always typed. Only the explicit native-client
    # package catalog may aggregate both types.
    @package_type = request.path_parameters[:package_type] || "plugin"
    if request.path_parameters[:package_catalog] && request.format.json?
      @package_type = params[:package_type].presence_in(Plugin::PACKAGE_TYPES)
    end
    @query = params[:q].to_s.strip
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : "downloads"
    @page = [ params[:page].to_i, 1 ].max
    @category = params[:category] if Registry::Taxonomy.category?(params[:category])
    @tag = params[:tag] if Registry::Taxonomy.tag?(params[:tag])
    @per_page = page_size
    @terms = parse_query(@query)

    # Plugins without a published version stay visible while genuinely in
    # review; burned names and rejected-only submissions don't pollute the
    # directory.
    scope = filtered_scope
    # id as tiebreaker: downloads/rating ties would otherwise let rows drift
    # between pages as OFFSET slides across an unstable order
    plugins = scope
      .select("plugins.*", "#{FIRST_PUBLISHED_SQL} AS first_published_at", "#{LAST_PUBLISHED_SQL} AS last_published_at")
      .order(Arel.sql(SORTS[@sort])).order(:id)
      .offset((@page - 1) * @per_page).limit(@per_page + 1).to_a
    @more = plugins.length > @per_page
    @plugins = plugins.first(@per_page)
    # Announced (and shown) only while filtering — the unfiltered count is
    # already in the hero stats. JSON always carries it: a native client
    # paginating a list needs to know how far the list goes.
    @total = scope.unscope(:select).count if @query.present? || @category || @tag || @package_type || request.format.json?
    @category_counts = package_scope.directory_visible.where.not(category: nil).group(:category).count
    # A short strip of genuinely new plugins on the unfiltered first page —
    # the default downloads sort would otherwise bury every fresh release.
    # Plus the popular shelf, same rule as the omarchy.org homepage's plugin
    # section: the most-installed plugins, independent of the directory's own
    # active sort/filter, so the top of the page always features what the
    # community actually installs.
    if @page == 1 && @query.blank? && @category.nil? && @tag.nil?
      visible = package_scope.directory_visible.includes(:publisher).with_previews
        .select("plugins.*", "#{FIRST_PUBLISHED_SQL} AS first_published_at", "#{LAST_PUBLISHED_SQL} AS last_published_at")
      @recent = visible
        .where("#{FIRST_PUBLISHED_SQL} >= ?", ApplicationHelper::CARD_RECENCY.ago)
        .order(Arel.sql("first_published_at DESC")).order(:id).limit(4)
      @popular = visible
        .order(Arel.sql(SORTS["downloads"])).order(:id).limit(6)
    end
    visible_packages = package_scope.directory_visible
    type_counts = visible_packages.group(:package_type).count
    @stats = {
      plugins: type_counts.fetch("plugin", 0),
      themes: type_counts.fetch("theme", 0),
      publishers: Publisher.claimed.where(id: visible_packages.select(:publisher_id)).count,
      downloads: visible_packages.sum(:downloads_count)
    }
    freshen(@plugins, @recent, @popular, @query, @sort, @category, @tag, @package_type, @page, @per_page, @more, @total, @stats.values)
  end

  private

  def redirect_legacy_theme_directory
    return if request.path_parameters[:package_type] || request.path_parameters[:package_catalog]
    return unless params[:package_type] == "theme"
    options = params.permit(:q, :sort, :page, :category, :tag, :per_page).to_h
    options[:format] = :json if request.format.json?
    redirect_to themes_path(options), status: :moved_permanently
  end

  def package_scope
    @package_type ? Plugin.where(package_type: @package_type) : Plugin.all
  end

  # Honoured for JSON only. The web grid stays at its designed 24: the pager
  # links don't carry per_page, so a bigger HTML page would silently snap back
  # to 24 on "Next" — a broken pager is worse than a fixed page size.
  def page_size
    return PER_PAGE unless request.format.json?
    requested = params[:per_page].to_i
    requested.positive? ? requested.clamp(1, MAX_PER_PAGE) : PER_PAGE
  end

  # The search box understands a few typed operators alongside plain text:
  # @publisher, tag:media, kind:bar, category:system. Everything else matches
  # name and summary.
  def parse_query(query)
    terms = { text: [], publishers: [], tags: [], kinds: [], categories: [] }
    query.split(/\s+/).each do |token|
      case token
      when /\A@(.+)\z/ then terms[:publishers] << $1.downcase
      when /\Atag:(.+)\z/i then terms[:tags] << $1.downcase
      when /\Akind:(.+)\z/i then terms[:kinds] << $1.downcase
      when /\Acategory:(.+)\z/i then terms[:categories] << $1.downcase
      else terms[:text] << token
      end
    end
    terms[:tags] << @tag if @tag
    terms[:categories] << @category if @category
    terms
  end

  def filtered_scope
    scope = package_scope.directory_visible.includes(:publisher).with_previews

    if @terms[:text].any?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(@terms[:text].join(' ').downcase)}%"
      # LOWER on both sides: SQLite LIKE is case-insensitive but PostgreSQL's
      # is not — normalize explicitly so both adapters match the same rows
      scope = scope.where(
        "LOWER(plugins.name) LIKE :q OR LOWER(plugins.summary) LIKE :q OR LOWER(plugins.normalized_name) LIKE :q", q: like)
    end
    if @terms[:publishers].any?
      scope = scope.joins(:publisher)
        .where(publishers: { normalized_name: @terms[:publishers].map { |p| NameRules.normalize(p) } })
    end
    scope = scope.where(category: @terms[:categories]) if @terms[:categories].any?
    @terms[:tags].each { |tag| scope = scope.where(json_membership("plugins.tags"), tag) }
    @terms[:kinds].each { |kind| scope = scope.where(json_membership("plugins.kinds"), kind) }
    scope
  end

  # Membership test inside a JSON-array column (SQLite json_each, same as the
  # trending window above — this app is SQLite in every environment).
  def json_membership(column)
    "EXISTS (SELECT 1 FROM json_each(#{column}) WHERE json_each.value = ?)"
  end
end
