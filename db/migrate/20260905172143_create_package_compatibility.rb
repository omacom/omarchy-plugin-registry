class CreatePackageCompatibility < ActiveRecord::Migration[8.1]
  def change
    create_table :omarchy_releases do |t|
      t.string :version, null: false
      t.string :build, null: false, default: ""
      t.string :channel, null: false, default: "stable"
      t.json :apis, null: false, default: {}
      t.timestamps
    end
    add_index :omarchy_releases, [ :version, :build ], unique: true
    add_check_constraint :omarchy_releases, "channel IN ('stable', 'candidate', 'development')", name: "release_channel"

    create_table :compatibility_assessments do |t|
      t.references :plugin_version, null: false, foreign_key: true
      t.references :omarchy_release, null: false, foreign_key: true
      t.string :decision, null: false, default: "none"
      t.text :reason, null: false, default: ""
      t.integer :revision, null: false, default: 0
      t.string :check_result, null: false, default: "not_run"
      t.text :check_evidence, null: false, default: ""
      t.integer :alert_level, null: false, default: 0
      t.timestamps
    end
    add_index :compatibility_assessments, [ :plugin_version_id, :omarchy_release_id ], unique: true, name: "assessment_identity"
    add_check_constraint :compatibility_assessments, "decision IN ('none', 'incompatible')", name: "compatibility_decision"
    add_check_constraint :compatibility_assessments, "check_result IN ('not_run', 'passed', 'failed', 'inconclusive')", name: "compatibility_check_result"
    add_check_constraint :compatibility_assessments, "revision >= 0 AND alert_level BETWEEN 0 AND 3", name: "compatibility_counters"

    create_table :compatibility_reports do |t|
      t.references :compatibility_assessment, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :outcome, null: false
      t.string :category, null: false
      t.text :details, null: false, default: ""
      t.boolean :modified, null: false, default: false
      t.timestamps
    end
    add_index :compatibility_reports, [ :compatibility_assessment_id, :user_id ], unique: true, name: "one_compatibility_report_per_user"
    add_check_constraint :compatibility_reports, "outcome IN ('works', 'problem')", name: "compatibility_report_outcome"
    add_check_constraint :compatibility_reports, "category IN ('appearance', 'activation', 'other', 'none')", name: "compatibility_report_category"

    create_table :compatibility_notifications do |t|
      t.references :compatibility_assessment, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :level, null: false
      t.datetime :sent_at
      t.timestamps
    end
    add_index :compatibility_notifications, [ :compatibility_assessment_id, :user_id, :level ], unique: true, name: "compatibility_notification_identity"
    add_index :compatibility_notifications, :sent_at
    add_check_constraint :compatibility_notifications, "level BETWEEN 1 AND 3", name: "compatibility_notification_level"
  end
end
