# frozen_string_literal: true

# A scenario of a live plan, with the period the tree gives it.
#
# Projected from the plan streams by {TeamPlanning::Projections::Scenarios},
# and nothing else writes it. Its id is the scenario's, so a rebuild keeps it.
# The baseline shares its plan's id, has no parent or relation, and starts on
# the plan's base date with no end.
#
class TeamPlanningScenario < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true

  # @return [Boolean]
  def baseline? = parent_id.nil?
end
