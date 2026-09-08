module PluginCardData
  extend ActiveSupport::Concern

  PUBLISHED_STATE = PluginVersion.states.fetch(:published)
  LATEST_SHA_SQL = ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, PUBLISHED_STATE ]).freeze
    (SELECT pv.sha256 FROM plugin_versions pv
      WHERE pv.plugin_id = plugins.id AND pv.state = ?
      ORDER BY pv.published_at DESC LIMIT 1)
  SQL
  SPARK_DAYS = 14
  COMMENT_PREVIEW_LIMIT = 2_000
  COMMENT_AUTHOR_LIMIT = 120

  private

  def daily_installs_for(plugins)
    ids = plugins.map(&:id)
    return {} if ids.empty?
    DailyDownload.joins(:plugin_version)
      .where(plugin_versions: { plugin_id: ids })
      .where(date: (SPARK_DAYS - 1).days.ago.to_date..Date.current)
      .group("plugin_versions.plugin_id", :date)
      .sum(:count)
  end

  def latest_comments_for(plugins)
    ids = plugins.map(&:id)
    return {} if ids.empty?

    Comment.visible.where(plugin_id: ids).includes(:user).where(<<~SQL.squish).index_by(&:plugin_id)
      NOT EXISTS (
        SELECT 1 FROM comments newer
        WHERE newer.plugin_id = comments.plugin_id
          AND newer.hidden_at IS NULL
          AND (newer.created_at > comments.created_at
            OR (newer.created_at = comments.created_at AND newer.id > comments.id))
      )
    SQL
  end
end
