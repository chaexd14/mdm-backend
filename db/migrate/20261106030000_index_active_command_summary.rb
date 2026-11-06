class IndexActiveCommandSummary < ActiveRecord::Migration[8.1]
  def change
    add_index :device_commands, :expires_at, where: "status IN ('pending', 'received')", name: "index_active_command_expiry"
  end
end
