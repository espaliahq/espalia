# frozen_string_literal: true

# Lets a member create Team Planning plans without being an admin (decision
# 7). It opens nobody else's plan.
#
# Approval is :in_app, as it changes someone's permissions.
class Operations::TeamPlanning::AddPlanner < Operations::Base
  include Operations::TeamPlanning::PlannerSupport

  description "Make an active person with an account in this organisation a planner, so they may create " \
              "Team Planning plans. It opens no plan they aren't a member of. Admins already may create " \
              "plans. Returns the list as team_planning_planners reads it."
  category :write
  approval :in_app

  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] planners and admins
  # @raise [ParameterError] for a person with no account, an admin, or someone who has left
  def perform
    account = account!
    raise ParameterError, "person_id: admins may already create plans" if account.admin?
    raise ParameterError, "person_id: only someone still in the organisation can be a planner" unless account.person&.status == "active"

    account.update!(team_planner: true)
    planners_payload
  end
end
