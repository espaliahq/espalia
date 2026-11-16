# frozen_string_literal: true

# A scenario removed from a live plan: its name and period as they stood, who
# removed it and when.
#
# Projected from the plan streams by {TeamPlanning::Projections::Scenarios},
# and nothing else writes it. Its id is the scenario's, so a rebuild keeps it.
# The name stays sealed under the plan's key. How many changes it held is
# {TeamPlanningRemovedScenarioTally}'s, joined by id.
#
class TeamPlanningRemovedScenario < ApplicationRecord
  include Shreddable::Column

  acts_as_tenant :tenant
  shreddable_column :name, by: :plan

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true
  belongs_to :removed_by, class_name: "Person", optional: true
end
