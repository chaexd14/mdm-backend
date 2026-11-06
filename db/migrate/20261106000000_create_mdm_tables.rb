class CreateMdmTables < ActiveRecord::Migration[7.2]
  def change
    create_table :devices do |t|
      t.string :device_id, null: false
      t.string :name, null: false
      t.string :location, default: "Manila", null: false
      t.string :os, default: "Android 14", null: false
      t.string :agent_version, default: "1.0.0", null: false
      t.string :app_version, default: "1.0.0", null: false
      t.datetime :last_seen
      t.boolean :maintenance_mode, default: false, null: false
      t.text :maintenance_message
      t.text :url, default: "https://app.hotel.dev.saikotechsolutions.com", null: false
      t.integer :refresh_interval, default: 30, null: false
      t.boolean :allow_transactions, default: true, null: false
      t.string :theme, default: "default", null: false
      t.integer :battery_level
      t.boolean :is_charging
      t.boolean :is_device_owner
      t.string :lock_task_state
      t.string :model
      t.string :manufacturer
      t.timestamps
    end
    add_index :devices, :device_id, unique: true
    create_table :device_commands, id: :string do |t|
      t.references :device, null: false, foreign_key: { on_delete: :cascade }
      t.string :command_type, null: false
      t.jsonb :payload, default: {}, null: false
      t.string :status, default: "pending", null: false
      t.datetime :executed_at
      t.timestamps
    end
    add_index :device_commands, [:device_id, :status, :created_at]
    add_check_constraint :device_commands, "status IN ('pending', 'executed', 'failed', 'cancelled')", name: "command_status"
    create_table :dashboard_events do |t|
      t.string :event_type, null: false
      t.jsonb :payload, default: {}, null: false
      t.datetime :created_at, null: false
    end
  end
end
