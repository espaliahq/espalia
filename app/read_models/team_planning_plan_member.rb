# frozen_string_literal: true

# One member of a live plan, as an editor or a viewer.
#
# Projected from the plan streams by {TeamPlanning::Projections::PlanMembers},
# and nothing else writes it. The id derives from the plan and the person, so
# a rebuild keeps it.
#
class TeamPlanningPlanMember < ApplicationRecord
  include DeterministicId
  deterministic_id_from :plan_id, :person_id

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true
  belongs_to :person, optional: true

  scope :editors, -> { where(role: "editor") }
end
