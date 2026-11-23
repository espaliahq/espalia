# frozen_string_literal: true

# Who may create Team Planning plans: the planners an admin chose, and the
# admins, who always may.
class Operations::TeamPlanning::Planners < Operations::Base
  include Operations::TeamPlanning::PlannerSupport

  description "List who may create Team Planning plans: the planners an admin chose, and the tenant's " \
              "admins, who always may. Each with a person id and name. Each planner also has since (the date it " \
              "took effect), added_by (who made them one, or null when no one did) and already_held (true " \
              "when they were a planner before Espalia recorded who gave it). Admins only."
  category :read
  approval :none

  # @return [Hash] planners and admins
  def perform = planners_payload
end
