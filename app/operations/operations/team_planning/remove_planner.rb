# frozen_string_literal: true

# Takes back a member's right to create plans. Plans they are already in stay
# theirs, as editor or viewer.
#
# Approval is :in_app, as it changes someone's permissions.
class Operations::TeamPlanning::RemovePlanner < Operations::Base
  include Operations::TeamPlanning::PlannerSupport

  description "Stop a person being a planner, so they may no longer create Team Planning plans. They stay " \
              "a member of the plans they are in. It reaches every account linked to them, an admin's " \
              "too, so a later demotion can't bring it back. " \
              "Refused when every account is an admin's and none carries the right. " \
              "Returns the list as team_planning_planners reads it."
  category :write
  approval :in_app

  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] planners and admins
  # @raise [ParameterError] for a person with no account, or only admin ones without the right
  def perform
    ensure_removable!(:team_planner, "an admin may always create plans")
    grant_handler.remove_from_person(:team_planner, params[:person_id].to_s.downcase, removed_by_id: context.person&.id)
    planners_payload
  end
end
