# frozen_string_literal: true

# What a scenario overrides, each beside what its parent would give it now.
#
# A pin whose parent has moved on says so, which is what drift and reconcile
# (4.4, 4.5) read [#239](https://github.com/espaliahq/espalia/issues/239).
class Operations::TeamPlanning::Overrides < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List what a scenario of a Team Planning plan the caller is in overrides: each subject and facet " \
              "it sets or pinned, its end state, its note when it has one (`{ value }`, or `{ removed: true }` once erased; a note on a pay change only for a member with the see-pay right), who set it and when. Each also shows what the scenario would " \
              "inherit without it: the nearest ancestor scenario that changes it, or the baseline. A pin names " \
              "where its value came from (a null scenario_id: read off its parent's organisation, as a rule " \
              "above the subject or the baseline gave it), and parent_moved whether its parent would now give " \
              "it something else. A " \
              "budget line's amount, currency and period reach only a member with the see-pay right. A " \
              "forgotten person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the " \
              "caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String]
  # @return [Array<Hash>] the scenario's overrides, by subject and facet
  def self.listed(context:, plan:, scenario_id:)
    rows = TeamPlanningOverride.where(scenario_id:).order(:subject_id, :facet).to_a
    names = Person.where(id: rows.map(&:set_by_id).compact.uniq).pluck(:id, :name).to_h
    inherits = Inherits.new(context:, plan:, scenario_id:, rows:)
    see_pay = PlanPolicy.new(context, plan).see_pay?
    rows.map do |row|
      note = Operations::TeamPlanning::ChangeNote.payload(row.note, facet: row.facet, see_pay:)
      above = inherits.of(row)
      above = above.merge(end_state: Operations::TeamPlanning::LineFigures.end_state(above[:end_state], facet: row.facet, see_pay:))
      end_state = Operations::TeamPlanning::LineFigures.end_state(row.end_state, facet: row.facet, see_pay:)
      { subject_id: row.subject_id, facet: row.facet, kind: row.kind.demodulize.underscore, end_state:,
        pinned: row.pinned, pinned_from: (pinned_from(row) if row.pinned), parent_moved: (above[:end_state] != end_state if row.pinned),
        inherits: above, set_by: { person_id: row.set_by_id, name: names.fetch(row.set_by_id, Person::FORMER_MEMBER) },
        set_at: row.set_at.utc.iso8601, **({ note: } if note) }
    end
  end

  def self.pinned_from(row) = { scenario_id: row.pinned_from_scenario_id, event_id: row.pinned_from_event_id }
  private_class_method :pinned_from

  # What a scenario's parent gives it for each override: the nearest ancestor
  # that changes the same key, or else what its kind reads off the parent's
  # resolved map, which a rule above the subject or the baseline decides.
  class Inherits
    # @param context [AuthorizationContext]
    # @param plan [TeamPlanningPlan]
    # @param scenario_id [String]
    # @param rows [Array<TeamPlanningOverride>]
    def initialize(context:, plan:, scenario_id:, rows:)
      @context = context
      @plan = plan
      @parent_id = TeamPlanningScenario.find_by(id: scenario_id)&.parent_id
      @above = nearest_above(rows)
    end

    # @param row [TeamPlanningOverride]
    # @return [Hash] `{ scenario_id, end_state }`, the scenario nil when no ancestor changes the key
    def of(row)
      found = @above[[ row.subject_id, row.facet ]]
      return { scenario_id: found.scenario_id, end_state: found.end_state } if found

      kind = row.kind.safe_constantize
      { scenario_id: nil, end_state: read_off_parent(kind, row)&.deep_stringify_keys }
    end

    private

    # A rule whose kind has since gone reads as nothing, not a failed listing.
    # Pay reads as its field alone, to holders too: the parent's map holds it
    # sealed, and a sealed Shreddable::Value refuses to serialise.
    def read_off_parent(kind, row)
      return unless @parent_id && kind&.readable?
      return { field: "pay" } if row.facet == ::TeamPlanning::Events::PlanDataSet::PAY_FACET

      kind.read_from(parent_map, subject_id: row.subject_id, facet: row.facet)
    rescue ::TeamPlanning::Error
      nil
    end

    def parent_map = @parent_map ||= ::TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id: @parent_id).structure

    def nearest_above(rows)
      scenarios = TeamPlanningScenario.where(plan_id: @plan.id).pluck(:id, :parent_id).to_h
      ancestors = []
      id = @parent_id
      while id && ancestors.exclude?(id)
        ancestors << id
        id = scenarios[id]
      end
      found = TeamPlanningOverride.where(scenario_id: ancestors, subject_id: rows.map(&:subject_id), facet: rows.map(&:facet))
      found.sort_by { -ancestors.index(it.scenario_id) }.index_by { [ it.subject_id, it.facet ] }
    end
  end

  # @return [Hash] `{ plan_id, scenario_id, overrides: [...] }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    unless TeamPlanningScenario.exists?(plan_id: plan.id, id: scenario_id)
      raise Operations::Base::ParameterError, "This plan has no such scenario"
    end

    { plan_id: plan.id, scenario_id:, overrides: self.class.listed(context:, plan:, scenario_id:) }
  end
end
