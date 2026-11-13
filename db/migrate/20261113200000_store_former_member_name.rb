# frozen_string_literal: true

# A forgotten person's row keeps the stand-in as its name, so every reader,
# a raw pluck included, shows them as a former member.
class StoreFormerMemberName < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE people SET name = 'Former member' WHERE forgotten_at IS NOT NULL"
    remove_check_constraint :people, name: "people_identified_unless_forgotten"
    change_column_null :people, :name, false
    add_check_constraint :people,
                         "(forgotten_at IS NULL AND email IS NOT NULL) OR (forgotten_at IS NOT NULL AND name = 'Former member')",
                         name: "people_identified_unless_forgotten"
  end

  def down
    remove_check_constraint :people, name: "people_identified_unless_forgotten"
    change_column_null :people, :name, true
    execute "UPDATE people SET name = NULL WHERE forgotten_at IS NOT NULL"
    add_check_constraint :people, "forgotten_at IS NOT NULL OR (name IS NOT NULL AND email IS NOT NULL)",
                         name: "people_identified_unless_forgotten"
  end
end
