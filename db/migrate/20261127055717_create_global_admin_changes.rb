# frozen_string_literal: true

class CreateGlobalAdminChanges < ActiveRecord::Migration[8.1]
  def up
    create_table :global_admin_changes, id: :uuid, default: nil do |t|
      t.uuid :user_id, null: false, index: true
      t.boolean :global_admin, null: false
      t.string :source, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :global_admin_changes, "source IN ('admin_task', 'seed', 'console', 'baseline')",
                         name: "global_admin_changes_source"

    # Postgres 16 has no uuidv7(), so the ids come from Ruby; the time comes from the database.
    holders = select_values("SELECT id FROM users WHERE global_admin ORDER BY created_at, id")
    return if holders.empty?

    rows = holders.map { |user_id| "(#{connection.quote(SecureRandom.uuid_v7)}, #{connection.quote(user_id)}, TRUE, 'baseline', CURRENT_TIMESTAMP)" }
    execute "INSERT INTO global_admin_changes (id, user_id, global_admin, source, created_at) VALUES #{rows.join(', ')}"
  end

  def down
    drop_table :global_admin_changes
  end
end
