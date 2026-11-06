class CreateAppUpdates < ActiveRecord::Migration[8.1]
  def change
    create_table :app_releases, id: :string do |t|
      t.string :package_name, null: false
      t.bigint :version_code, null: false
      t.string :version_name, null: false
      t.integer :min_sdk, null: false
      t.jsonb :abis, default: [], null: false
      t.string :sha256, null: false
      t.string :signer_sha256, null: false
      t.bigint :byte_size, null: false
      t.string :storage_key, null: false
      t.boolean :debug_build, default: false, null: false
      t.boolean :require_app_ready, default: false, null: false
      t.text :notes
      t.string :state, default: 'draft', null: false
      t.timestamps
    end
    add_index :app_releases, [:package_name, :version_code], unique: true
    create_table :device_updates, id: :string do |t|
      t.references :device, null: false, foreign_key: true
      t.references :app_release, type: :string, null: false, foreign_key: true
      t.string :policy, null: false, default: 'approval'
      t.string :desired_state, null: false, default: 'active'
      t.integer :attempt_number, null: false, default: 1
      t.datetime :not_before
      t.datetime :window_end
      t.timestamps
    end
    add_index :device_updates, :device_id, unique: true, where: "desired_state = 'active'", name: 'one_active_device_update'
    create_table :update_attempts do |t|
      t.references :device_update, type: :string, null: false, foreign_key: true
      t.integer :attempt_number, null: false
      t.bigint :sequence, null: false, default: 0
      t.string :state, null: false, default: 'assigned'
      t.integer :progress, null: false, default: 0
      t.bigint :bytes_downloaded, null: false, default: 0
      t.integer :installer_session_id
      t.string :error_code
      t.text :error_message
      t.bigint :installed_version_code
      t.datetime :installed_at
      t.datetime :confirmed_at
      t.datetime :last_reported_at
      t.timestamps
    end
    add_index :update_attempts, [:device_update_id, :attempt_number], unique: true
  end
end
