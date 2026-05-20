# frozen_string_literal: true

class CreateTenantUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :tenant_users, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :person, type: :uuid, null: true, foreign_key: true
      t.string :role, null: false, default: "member"

      t.timestamps null: false
    end

    add_index :tenant_users, [ :tenant_id, :user_id ], unique: true
  end
end
