# frozen_string_literal: true

# A plan that has not been deleted, with its name, base date and creator.
#
# Projected from the plan streams by {TeamPlanning::Projections::Plans}, and
# nothing else writes it. Its id is the plan's, so a rebuild keeps it. Its
# members come from {TeamPlanningPlanMember}, which another projection writes.
#
class TeamPlanningPlan < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  has_many :members, class_name: "TeamPlanningPlanMember", foreign_key: :plan_id, inverse_of: :plan,
                     dependent: nil

  # @param person_id [String, nil]
  # @return [String, nil] "editor", "viewer", or nil for a non-member
  def role_of(person_id) = members.find { it.person_id == person_id }&.role

  # @return [Array<String>] person ids
  def editor_ids = members.select { it.role == "editor" }.map(&:person_id)
end
