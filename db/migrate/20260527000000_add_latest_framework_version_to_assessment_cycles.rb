# frozen_string_literal: true

# Lets a cycle express the FULL RANGE of framework versions it has been
# open against, not just the version it was originally defined at.
#
# Before this column, the read model only held `framework_version` —
# the value frozen at `CycleDefined` time. After PR #119, the data
# inside an open cycle actually moves to the survivor capabilities of
# whatever the latest published version says, but the cycle row kept
# saying "v1" even when its ratings had migrated to v2. This column
# closes that display + reporting gap by tracking the highest version
# the cycle has been rolled forward through.
#
# Backfilled to `framework_version` so existing cycles read as a
# single-version range until a future publish updates them.
class AddLatestFrameworkVersionToAssessmentCycles < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycles, :latest_framework_version, :integer

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE assessment_cycles
          SET latest_framework_version = framework_version
          WHERE latest_framework_version IS NULL
        SQL
      end
    end

    change_column_null :assessment_cycles, :latest_framework_version, false
  end
end
