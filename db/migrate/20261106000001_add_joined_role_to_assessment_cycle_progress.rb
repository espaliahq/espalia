# frozen_string_literal: true

# The role and level held when the person joined the cycle: the home the
# aggregate fixes, which a role-less (pre-ADR-22) alignment event belongs to
# after a mid-cycle role change has moved the enrollment snapshot
# (https://github.com/mr-yum/growth-os/issues/673).
class AddJoinedRoleToAssessmentCycleProgress < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycle_progress, :joined_role_id, :uuid
    add_column :assessment_cycle_progress, :joined_level_id, :uuid
  end
end
