# frozen_string_literal: true

# A scenario of a live plan, with the period the tree gives it.
#
# Projected from the plan streams by {TeamPlanning::Projections::Scenarios},
# and nothing else writes it. Its id is the scenario's, so a rebuild keeps it.
# The baseline shares its plan's id, has no parent or relation, and starts on
# the plan's base date with no end. The name is sealed under the plan's key.
#
class TeamPlanningScenario < ApplicationRecord
  include Shreddable::Column

  acts_as_tenant :tenant
  shreddable_column :name, by: :plan

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true

  # A baseline's name is the app's own, so its row holds none.
  BASELINE_NAME = "Baseline"

  # @return [Boolean]
  def baseline? = parent_id.nil?

  # @return [Shreddable::Value, nil]
  def name = baseline? ? Shreddable::Value.wrap(BASELINE_NAME) : shreddable_value(:name)
end
