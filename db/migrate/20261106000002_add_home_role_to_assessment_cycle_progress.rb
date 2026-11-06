# frozen_string_literal: true

# The cycle's home role and level as `CurrentAssessment` tracks it from its
# own events: the role held at the join, moved by a promotion or transfer
# until alignment starts (https://github.com/mr-yum/growth-os/issues/687).
# `joined_role_id` / `joined_level_id` are ignored from here and dropped once
# no deployed release writes them. The assignment's `current_cycle_id` names
# the cycle a role change lands in, as the aggregate's `@current_cycle_id`
# does.
class AddHomeRoleToAssessmentCycleProgress < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycle_progress, :home_role_id, :uuid
    add_column :assessment_cycle_progress, :home_level_id, :uuid
    add_column :person_framework_assignments, :current_cycle_id, :uuid
  end
end
