# frozen_string_literal: true

# What the plan page's Undo and Redo buttons would act on for the caller in
# one scenario ([#424](https://github.com/espaliahq/espalia/issues/424)). It
# picks as `team_planning_undo_change` and `team_planning_redo_change` do with
# no event_id, skipping the facets the caller may no longer touch, so a member
# without the see-pay right is never offered a pay change, nor told one
# exists. It offers nothing the operation would refuse, on scope or on a
# departure's day.
class Operations::TeamPlanning::UndoStep < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::WithinScope

  DATES = "dates"

  description "Get what the caller's Undo and Redo would act on in a scenario of a Team Planning plan: undo is " \
              "their own latest change, pin, clear or move there that can still be undone, and redo the change " \
              "their latest undo took back that can still be redone, each as team_planning_undo_change and " \
              "team_planning_redo_change pick one with no event_id. Each is { event_id, action, subject_id, " \
              "subject, facet, scenario_id } or null: action is set, clear, move or dates, subject the name of a " \
              "person or unit (null for anything else), and a dates entry has no subject or facet and names the " \
              "step whose dates it set in scenario_id. Neither ever names a value. A pay change is offered only to " \
              "a member with the see-pay right; anyone else is offered their latest other change, or null. Both " \
              "are null for a viewer, for the baseline, and for an archived or frozen plan, and when the change is " \
              "about someone or something outside the units a scoped plan covers. An undo of a clear that " \
              "brings someone back into those units is offered with subject null, since the plan covers them " \
              "only once it lands. Refused, as an unknown plan, " \
              "unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, undo, redo }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    known_scenario!(plan, scenario_id)
    return { plan_id: plan.id, scenario_id:, undo: nil, redo: nil } unless offered?(plan, scenario_id)

    aggregate = ::TeamPlanning::Repository.new.load_plan(plan.id)
    except_facets = ::Operations::TeamPlanning::ChangeNote.hidden_facets(see_pay: PlanPolicy.new(context, plan).see_pay?)
    actor_id = context.person.id
    undo_id = aggregate.last_undoable_by(scenario_id, actor_id, except_facets:)
    redo_id = aggregate.last_redoable_by(scenario_id, actor_id, except_facets:)
    hidden = Hidden.new(context, plan, scenario_id)
    undo_offer = step(aggregate, scenario_id, undo_id, hidden) { aggregate.restored_by_undo(scenario_id, undo_id) }
    redo_offer = step(aggregate, scenario_id, redo_id, hidden) { |entry| entry if entry.is_a?(::TeamPlanning::Events::Change) }
    { plan_id: plan.id, scenario_id:,
      undo: accepted(plan, undo_offer) { it.undo_change(scenario_id:, event_id: undo_id, undone_by_id: actor_id) },
      redo: accepted(plan, redo_offer) { it.redo_change(scenario_id:, event_id: redo_id, redone_by_id: actor_id) } }
  end

  private

  def offered?(plan, scenario_id)
    scenario_id != plan.id && !plan.archived? && !PlanPolicy.frozen?(plan) && context.person && PlanPolicy.new(context, plan).update?
  end

  # @yieldparam entry [RubyEventStore::Event] the entry to undo or redo
  # @yieldreturn [TeamPlanning::Events::Change, nil] the change it would put in effect, held against the plan's
  #   scope; with none, the entry itself is, so a change to a line the plan hides is never named
  def step(aggregate, scenario_id, event_id, hidden)
    return nil unless event_id

    entry = aggregate.log_of(scenario_id).find { it.event_id == event_id }
    return dates(event_id) unless entry

    held = yield(entry) || entry
    within_scope!(aggregate, held.class, held.data[:subject_id], held.data)

    subject_id = entry.data[:subject_id]
    { event_id:, action: action_of(entry), subject_id:, subject: name_of(subject_id, hidden), facet: aggregate.facet_of(scenario_id, event_id), scenario_id: }
  rescue Operations::Base::ParameterError
    nil
  end

  # The plan refuses an undo or redo that a later change has made impossible:
  # a departure outside dates an undo brings back, a move whose source step now
  # changes the same thing. Trying it on a copy that is never stored asks the
  # plan itself, so the offer can't drift from what it accepts.
  def accepted(plan, offer)
    return nil unless offer

    yield ::TeamPlanning::Repository.new.load_plan(plan.id)
    offer
  rescue ::TeamPlanning::Error
    nil
  end

  # A step's dates sit on the step itself, which for an alternative or half of
  # a split is not the scenario asked about.
  def dates(event_id)
    event = Rails.configuration.event_store.read.event(event_id)
    { event_id:, action: DATES, subject_id: nil, subject: nil, facet: nil, scenario_id: event.data[:scenario_id] }
  end

  def action_of(entry)
    case entry
    when ::TeamPlanning::Events::ChangeCleared then "clear"
    when ::TeamPlanning::Events::ChangeMoved then "move"
    else "set"
    end
  end

  # The scope hides the name of anyone status reads as outside, even when the
  # undo on offer would bring them back in ([#435](https://github.com/espaliahq/espalia/issues/435)).
  def name_of(subject_id, hidden)
    return nil if hidden.include?(subject_id)

    Person.find_by(id: subject_id)&.name || OrgUnit.find_by(id: subject_id)&.name
  end

  # Outside both the scenario and the baseline, as {TeamPlanning::Status} reads it.
  # Resolved only when a name is asked for, and never on an unscoped plan.
  Hidden = Struct.new(:context, :plan, :scenario_id) do
    def include?(subject_id) = ids.include?(subject_id)

    private

    def ids
      @ids ||= plan.scope_unit_ids.blank? ? Set.new : outside(::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure) &
                                                       outside(::TeamPlanning::Baseline.new(context:, plan:).structure)
    end

    def outside(map) = map.outside_ids | map.cut_ids
  end
end
