class CreateMyOmarchy < ActiveRecord::Migration[8.1]
  def change
    # A token's purpose decides which API it can reach: publish tokens push
    # plugin versions, account tokens are what a machine holds for My Omarchy
    # (dotfile sync, snap sharing, the voice key). Neither authorizes the
    # other's surface. device_name is the hostname the CLI reported so the
    # devices page reads "framework-laptop" instead of a digest hint.
    add_column :api_tokens, :purpose, :integer, default: 0, null: false
    add_column :api_tokens, :device_name, :string
    add_column :device_authorizations, :purpose, :integer, default: 0, null: false
    add_column :device_authorizations, :device_name, :string

    # One immutable snapshot per push. The archive is an Active Storage blob
    # (opaque when the client encrypted it); the manifest is the clear list of
    # paths inside so the web can show what a bundle holds without opening it.
    create_table :dotfile_bundles do |t|
      t.references :user, null: false, foreign_key: true
      t.references :api_token, foreign_key: { on_delete: :nullify }
      t.string :device_name
      t.string :sha256, null: false
      t.integer :size_bytes, null: false
      t.integer :file_count, null: false, default: 0
      t.integer :encryption, null: false, default: 0
      t.json :manifest, null: false, default: {}
      t.timestamps
    end
    add_index :dotfile_bundles, [ :user_id, :created_at ]

    # A shared screenshot. The token is the whole access control for the
    # public page — unguessable, never enumerable, never in a sitemap.
    create_table :snaps do |t|
      t.references :user, null: false, foreign_key: true
      t.references :api_token, foreign_key: { on_delete: :nullify }
      t.string :token, null: false
      t.string :title
      t.string :device_name
      t.string :content_type, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.integer :byte_size, null: false
      t.integer :views_count, null: false, default: 0
      t.datetime :expires_at
      t.datetime :hidden_at
      t.timestamps
    end
    add_index :snaps, :token, unique: true
    add_index :snaps, [ :user_id, :created_at ]
    add_index :snaps, :expires_at

    # A per-user OpenRouter key minted through the management API, spend-capped
    # per month and time-boxed. The secret is encrypted at rest so a second
    # machine can fetch it; provider_hash is OpenRouter's id for the key.
    create_table :voice_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false, default: "openrouter"
      t.string :provider_hash, null: false
      t.string :label
      t.text :secret
      t.decimal :monthly_limit_usd, precision: 8, scale: 2, null: false
      t.decimal :usage_usd, precision: 10, scale: 4, null: false, default: 0
      t.decimal :usage_monthly_usd, precision: 10, scale: 4, null: false, default: 0
      t.datetime :usage_synced_at
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.datetime :provider_deleted_at
      t.string :device_name
      t.timestamps
    end
    add_index :voice_keys, :provider_hash, unique: true
  end
end
