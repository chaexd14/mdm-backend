class AddDeviceReadiness < ActiveRecord::Migration[8.1]
  def change
    add_column :devices, :web_health, :jsonb, default: {}, null: false
    add_column :devices, :journal_persistence_pending, :boolean, default: false, null: false
    add_column :devices, :lock_version, :integer, default: 0, null: false
  end
end
