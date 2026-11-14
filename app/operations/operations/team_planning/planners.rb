# frozen_string_literal: true

# Who may create Team Planning plans: the planners an admin chose, and the
# admins, who always may.
class Operations::TeamPlanning::Planners < Operations::Base
  include Operations::TeamPlanning::PlannerSupport

  description "List who may create Team Planning plans: the planners an admin chose, and the tenant's " \
              "admins, who always may. Each with a person id and name. Admins only."
  category :read
  approval :none

  # @return [Hash] planners and admins
  def perform = planners_payload
end
