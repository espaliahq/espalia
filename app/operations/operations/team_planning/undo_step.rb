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
              "about someone or something outside the units a scoped plan covers. Refused, as an unknown plan, " \
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
    { plan_id: plan.id, scenario_id:,
      undo: step(aggregate, scenario_id, undo_id) { aggregate.restored_by_undo(scenario_id, undo_id) },
      redo: step(aggregate, scenario_id, redo_id) { |entry| entry if entry.is_a?(::TeamPlanning::Events::Change) } }
  end

  private

  def offered?(plan, scenario_id)
    scenario_id != plan.id && !plan.archived? && !PlanPolicy.frozen?(plan) && context.person && PlanPolicy.new(context, plan).update?
  end

  # @yieldparam entry [RubyEventStore::Event] the entry to undo or redo
  # @yieldreturn [TeamPlanning::Events::Change, nil] the change it would put in effect, held against the plan's scope
  def step(aggregate, scenario_id, event_id)
    return nil unless event_id

    entry = aggregate.log_of(scenario_id).find { it.event_id == event_id }
    return dates(event_id) unless entry

    restored = yield(entry)
    within_scope!(aggregate, restored.class, restored.data[:subject_id], restored.data) if restored
    return nil unless entry.is_a?(::TeamPlanning::Events::ChangeMoved) || aggregate.leaves_in_period?(scenario_id, restored)

    subject_id = entry.data[:subject_id]
    { event_id:, action: action_of(entry), subject_id:, subject: name_of(subject_id), facet: aggregate.facet_of(scenario_id, event_id), scenario_id: }
  rescue Operations::Base::ParameterError
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

  def name_of(subject_id)
    Person.find_by(id: subject_id)&.name || OrgUnit.find_by(id: subject_id)&.name
  end
end
