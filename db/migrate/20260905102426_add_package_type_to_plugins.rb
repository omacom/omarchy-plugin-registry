class AddPackageTypeToPlugins < ActiveRecord::Migration[8.1]
  def change
    add_column :plugins, :package_type, :string, null: false, default: "plugin"
    add_index :plugins, :package_type
    add_check_constraint :plugins, "package_type IN ('plugin', 'theme')", name: "plugins_package_type"
  end
end
