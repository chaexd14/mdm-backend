class CreateAdminAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_accounts do |t|
      t.string :username, null: false
      t.string :password_digest, null: false
      t.boolean :active, null: false, default: true
      t.integer :failed_login_attempts, null: false, default: 0
      t.datetime :locked_until
      t.timestamps
    end
    add_index :admin_accounts, :username, unique: true
    create_table :admin_sessions do |t|
      t.references :admin_account, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :admin_sessions, :token_digest, unique: true
    add_index :admin_sessions, :expires_at
  end
end
