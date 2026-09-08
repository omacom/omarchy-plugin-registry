class AddTimestampsToDailyDownloads < ActiveRecord::Migration[8.1]
  def up
    add_column :daily_downloads, :created_at, :datetime
    add_column :daily_downloads, :updated_at, :datetime

    now = connection.quote(Time.current)
    execute <<~SQL.squish
      UPDATE daily_downloads
      SET created_at = #{now}, updated_at = #{now}
      WHERE created_at IS NULL OR updated_at IS NULL
    SQL

    change_column_null :daily_downloads, :created_at, false
    change_column_null :daily_downloads, :updated_at, false
  end

  def down
    remove_column :daily_downloads, :updated_at
    remove_column :daily_downloads, :created_at
  end
end
