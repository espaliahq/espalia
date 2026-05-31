# frozen_string_literal: true

# Records the framework version a participant's cycle was assessed against at
# alignment completion (the join version, advanced by any mid-cycle migration).
# Lets reporting attribute a completed assessment to its version without
# replaying the PersonDev stream. Populated from FullAlignmentCompleted by the
# CurrentAssessment projection.
#
# Nullable: completions that predate this capture remain nil.
class AddAlignedFrameworkVersionToCycleProgress < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycle_progress, :aligned_framework_version, :integer
  end
end
