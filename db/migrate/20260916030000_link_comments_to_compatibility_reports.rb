class LinkCommentsToCompatibilityReports < ActiveRecord::Migration[8.1]
  def change
    add_reference :comments, :compatibility_report, foreign_key: true, index: { unique: true }
  end
end
