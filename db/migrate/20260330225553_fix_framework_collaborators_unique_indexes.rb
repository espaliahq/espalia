# frozen_string_literal: true

# Fixes uniqueness enforcement on framework_collaborators.
#
# PostgreSQL treats NULL != NULL in unique indexes, so the original
# composite index cannot prevent duplicate unscoped collaborators
# (scope_type and scope_id both NULL). Replace it with two partial
# unique indexes — one for unscoped and one for scoped rows — and
# add a check constraint ensuring scope_type and scope_id are
# always both NULL or both NOT NULL.
#
class FixFrameworkCollaboratorsUniqueIndexes < ActiveRecord::Migration[8.1]
  def change
    # Remove the original index that can't enforce uniqueness on NULLs
    remove_index :framework_collaborators, name: "idx_framework_collaborators_unique"

    # Unscoped collaborators: scope_type and scope_id are both NULL
    add_index :framework_collaborators,
              [ :framework_id, :person_id, :role ],
              unique: true,
              where: "scope_type IS NULL AND scope_id IS NULL",
              name: "idx_framework_collaborators_unscoped_unique"

    # Scoped collaborators: scope_type and scope_id are both present
    add_index :framework_collaborators,
              [ :framework_id, :person_id, :role, :scope_type, :scope_id ],
              unique: true,
              where: "scope_type IS NOT NULL AND scope_id IS NOT NULL",
              name: "idx_framework_collaborators_scoped_unique"

    # Ensure scope_type and scope_id are always both NULL or both NOT NULL
    add_check_constraint :framework_collaborators,
                         "(scope_type IS NULL) = (scope_id IS NULL)",
                         name: "chk_framework_collaborators_scope_consistency"
  end
end
