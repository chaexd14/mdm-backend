class AddReliableDelivery < ActiveRecord::Migration[8.1]
  def change
    add_column :devices, :credential_digest, :string
    add_column :devices, :enrollment_digest, :string
    add_column :devices, :enrollment_expires_at, :datetime
    add_column :devices, :config_version, :integer, default: 1, null: false
    add_column :devices, :applied_config_version, :integer, default: 0, null: false
    add_column :devices, :current_url, :text
    add_column :devices, :reported_maintenance_mode, :boolean
    add_column :device_commands, :expires_at, :datetime
    add_column :device_commands, :received_at, :datetime
    add_column :device_commands, :lease_until, :datetime
    add_column :device_commands, :delivery_attempts, :integer, default: 0, null: false
    add_column :device_commands, :error, :text
    add_column :device_commands, :idempotency_key, :string
    add_index :device_commands, [:device_id, :idempotency_key], unique: true
    remove_check_constraint :device_commands, name: 'command_status'
    add_check_constraint :device_commands, "status IN ('pending','received','executed','failed','cancelled','expired')", name: 'command_status'
    reversible do |dir|
      dir.up { execute "UPDATE device_commands SET expires_at = created_at + INTERVAL '24 hours' WHERE expires_at IS NULL" }
    end
  end
end
