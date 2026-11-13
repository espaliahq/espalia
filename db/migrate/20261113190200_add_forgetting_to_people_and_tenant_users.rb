# frozen_string_literal: true

class AddForgettingToPeopleAndTenantUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :people, bulk: true do |t|
      t.datetime :forgotten_at
      t.string :forgotten_external_id_digest
      t.change_null :name, true
      t.change_null :email, true
      t.check_constraint "forgotten_at IS NOT NULL OR (name IS NOT NULL AND email IS NOT NULL)",
                         name: "people_identified_unless_forgotten"
      t.index %i[tenant_id forgotten_external_id_digest], unique: true,
                                                          where: "forgotten_external_id_digest IS NOT NULL"
    end

    change_table :tenant_users, bulk: true do |t|
      t.datetime :forgotten_at
      t.change_null :user_id, true
      t.check_constraint "forgotten_at IS NOT NULL OR user_id IS NOT NULL", name: "tenant_users_linked_unless_forgotten"
    end
  end
end
