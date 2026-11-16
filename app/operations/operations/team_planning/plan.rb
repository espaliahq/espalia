# frozen_string_literal: true

# One plan the caller is in.
class Operations::TeamPlanning::Plan < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get one Team Planning plan the caller is a member of: its name, base date, the caller's role " \
              "in it (editor or viewer), the units it covers (scope: the whole organisation, or chosen units, each with " \
              "everything under it), and whether it is frozen, which means no editor can still reach it, " \
              "so its viewers read it and nobody changes it. archived is null for a live plan, else the day it was archived " \
              "and who archived it (a forgotten person reads as \"#{Person::FORMER_MEMBER}\"), with priced_on the day its figures are priced as on, " \
              "null when they use today's: an archived plan takes no changes until an editor restores it, and its members can " \
              "still leave. Refused, as an unknown plan, unless the caller " \
              "is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, name, base_on, role, scope, frozen, archived }`
  def perform
    plan = plan!
    { plan_id: plan.id, name: plan.name&.reveal, base_on: plan.base_on.iso8601, role: plan.role_of(context.person.id),
      scope: self.class.scope_of(plan), frozen: PlanPolicy.frozen?(plan), archived: archived(plan) }
  end

  # @param plan [TeamPlanningPlan]
  # @return [Hash] `{ whole_organisation, units: [{ unit_id, name }] }`, units by name with any former unit last
  def self.scope_of(plan)
    ids = plan.scope_unit_ids.to_a
    names = OrgUnit.where(id: ids).pluck(:id, :name).to_h
    units = ids.map { { unit_id: it, name: names[it] } }.sort_by { [ it[:name] ? 0 : 1, it[:name].to_s, it[:unit_id] ] }
    { whole_organisation: ids.empty?, units: }
  end

  private

  # @return [Hash, nil] `{ on, by_id, by_name, priced_on }`
  def archived(plan)
    return unless plan.archived?

    { on: plan.archived_on.iso8601, by_id: plan.archived_by_id, by_name: Person.find_by(id: plan.archived_by_id)&.name,
      priced_on: ::TeamPlanning::PricingInputs.for(plan).frozen_on&.iso8601 }
  end
end
