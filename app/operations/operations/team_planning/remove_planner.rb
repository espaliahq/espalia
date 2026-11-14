# frozen_string_literal: true

# Takes back a member's right to create plans. Plans they are already in stay
# theirs, as editor or viewer.
#
# Approval is :in_app, as it changes someone's permissions.
class Operations::TeamPlanning::RemovePlanner < Operations::Base
  include Operations::TeamPlanning::PlannerSupport

  description "Stop a person being a planner, so they may no longer create Team Planning plans. They stay " \
              "a member of the plans they are in. An admin's right can't be removed this way. Returns the " \
              "list as team_planning_planners reads it."
  category :write
  approval :in_app

  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] planners and admins
  # @raise [ParameterError] for a person with no account, or an admin
  def perform
    account = account!
    raise ParameterError, "person_id: an admin may always create plans" if account.admin?

    account.update!(team_planner: false)
    planners_payload
  end
end
