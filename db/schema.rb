# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_06_040000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "app_releases", id: :string, force: :cascade do |t|
    t.string "package_name", null: false
    t.bigint "version_code", null: false
    t.string "version_name", null: false
    t.integer "min_sdk", null: false
    t.jsonb "abis", default: [], null: false
    t.string "sha256", null: false
    t.string "signer_sha256", null: false
    t.bigint "byte_size", null: false
    t.string "storage_key", null: false
    t.boolean "debug_build", default: false, null: false
    t.boolean "require_app_ready", default: false, null: false
    t.text "notes"
    t.string "state", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["package_name", "version_code"], name: "index_app_releases_on_package_name_and_version_code", unique: true
  end

  create_table "dashboard_events", force: :cascade do |t|
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
  end

  create_table "device_commands", id: :string, force: :cascade do |t|
    t.bigint "device_id", null: false
    t.string "command_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "executed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "expires_at"
    t.datetime "received_at"
    t.datetime "lease_until"
    t.integer "delivery_attempts", default: 0, null: false
    t.text "error"
    t.string "idempotency_key"
    t.index ["device_id", "idempotency_key"], name: "index_device_commands_on_device_id_and_idempotency_key", unique: true
    t.index ["device_id", "status", "created_at"], name: "index_device_commands_on_device_id_and_status_and_created_at"
    t.index ["device_id"], name: "index_device_commands_on_device_id"
    t.index ["expires_at"], name: "index_active_command_expiry", where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('received'::character varying)::text]))"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'received'::character varying::text, 'executed'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text, 'expired'::character varying::text])", name: "command_status"
  end

  create_table "device_updates", id: :string, force: :cascade do |t|
    t.bigint "device_id", null: false
    t.string "app_release_id", null: false
    t.string "policy", default: "approval", null: false
    t.string "desired_state", default: "active", null: false
    t.integer "attempt_number", default: 1, null: false
    t.datetime "not_before"
    t.datetime "window_end"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_release_id"], name: "index_device_updates_on_app_release_id"
    t.index ["device_id"], name: "index_device_updates_on_device_id"
    t.index ["device_id"], name: "one_active_device_update", unique: true, where: "((desired_state)::text = 'active'::text)"
  end

  create_table "devices", force: :cascade do |t|
    t.string "device_id", null: false
    t.string "name", null: false
    t.string "location", default: "Manila", null: false
    t.string "os", default: "Android 14", null: false
    t.string "agent_version", default: "1.0.0", null: false
    t.string "app_version", default: "1.0.0", null: false
    t.datetime "last_seen"
    t.boolean "maintenance_mode", default: false, null: false
    t.text "maintenance_message"
    t.text "url", default: "https://app.hotel.dev.saikotechsolutions.com", null: false
    t.integer "refresh_interval", default: 30, null: false
    t.boolean "allow_transactions", default: true, null: false
    t.string "theme", default: "default", null: false
    t.integer "battery_level"
    t.boolean "is_charging"
    t.boolean "is_device_owner"
    t.string "lock_task_state"
    t.string "model"
    t.string "manufacturer"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "credential_digest"
    t.string "enrollment_digest"
    t.datetime "enrollment_expires_at"
    t.integer "config_version", default: 1, null: false
    t.integer "applied_config_version", default: 0, null: false
    t.text "current_url"
    t.boolean "reported_maintenance_mode"
    t.jsonb "web_health", default: {}, null: false
    t.boolean "journal_persistence_pending", default: false, null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["device_id"], name: "index_devices_on_device_id", unique: true
  end

  create_table "update_attempts", force: :cascade do |t|
    t.string "device_update_id", null: false
    t.integer "attempt_number", null: false
    t.bigint "sequence", default: 0, null: false
    t.string "state", default: "assigned", null: false
    t.integer "progress", default: 0, null: false
    t.bigint "bytes_downloaded", default: 0, null: false
    t.integer "installer_session_id"
    t.string "error_code"
    t.text "error_message"
    t.bigint "installed_version_code"
    t.datetime "installed_at"
    t.datetime "confirmed_at"
    t.datetime "last_reported_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_update_id", "attempt_number"], name: "index_update_attempts_on_device_update_id_and_attempt_number", unique: true
    t.index ["device_update_id"], name: "index_update_attempts_on_device_update_id"
  end

  add_foreign_key "device_commands", "devices", on_delete: :cascade
  add_foreign_key "device_updates", "app_releases"
  add_foreign_key "device_updates", "devices"
  add_foreign_key "update_attempts", "device_updates"
end
