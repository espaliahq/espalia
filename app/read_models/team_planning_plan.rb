# frozen_string_literal: true

# A plan that has not been deleted, with its name, base date and creator,
# and the day it was archived and by whom while it stays archived.
# The name is sealed under the plan's key: show it with
# {Components::Shared::ShreddableText}, and never order or match by it.
#
# Projected from the plan streams by {TeamPlanning::Projections::Plans}, and
# nothing else writes it. Its id is the plan's, so a rebuild keeps it. Its
# members come from {TeamPlanningPlanMember}, which another projection writes.
#
class TeamPlanningPlan < ApplicationRecord
  include Shreddable::Column

  acts_as_tenant :tenant
  shreddable_column :name, by: :plan, plan: :id

  belongs_to :tenant
  has_many :members, class_name: "TeamPlanningPlanMember", foreign_key: :plan_id, inverse_of: :plan,
                     dependent: nil

  scope :live, -> { where(archived_on: nil) }
  scope :archived, -> { where.not(archived_on: nil) }

  # @return [Boolean]
  def archived? = !archived_on.nil?

  # @param person_id [String, nil]
  # @return [String, nil] "editor", "viewer", or nil for a non-member
  def role_of(person_id) = members.find { it.person_id == person_id }&.role

  # @return [Array<String>] person ids
  def editor_ids = members.select { it.role == "editor" }.map(&:person_id)

  # @param person_id [String, nil]
  # @return [Boolean] whether they hold the see-pay right
  def sees_pay?(person_id) = members.any? { it.person_id == person_id && it.see_pay }

  # @return [Array<String>] person ids
  def pay_holder_ids = members.select(&:see_pay).map(&:person_id)
end
