# frozen_string_literal: true

# What the plan reads share: the plan they name, found only among the
# caller's own plans, so a plan they aren't in reads as an unknown id.
#
# A plan keeps one editor who is still in the organisation
# [#203](https://github.com/espaliahq/espalia/issues/203). Being a tenant
# admin, a planner or an Org Graph editor opens no plan:
# test/integration/team_planning_privacy_test.rb walks every tool to hold
# that.
module Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::PlanWrite

  # What a read that checks a plan against the organisation says once the plan
  # is archived, in its description.
  UNCHECKED = "An archived plan is not checked: it returns checked: false, archived_on and a note, with nothing " \
              "listed, so an empty list never reads as nothing wrong. Restoring the plan checks it again; otherwise " \
              "checked is true."

  # What a read that prices a plan says once the plan is archived, in its description.
  PRICED_AS_ARCHIVED = "An archived plan carries archived_on, frozen_on and a note: its figures use the pay bands, exchange " \
                       "rates, budget lines and rules as they stood on frozen_on, its archive day, while framework roles and " \
                       "levels are read as they are now. A plan archived before that copy was kept has no frozen_on, and its " \
                       "figures use today's. Restoring a plan prices it with today's again."

  private

  # @param plan [TeamPlanningPlan]
  # @return [Hash] `{ checked: false, archived_on, note }` for an archived plan, else `{ checked: true }`
  def checked(plan)
    return { checked: true } unless plan.archived?

    { checked: false, archived_on: plan.archived_on.iso8601,
      note: "This plan was archived on #{plan.archived_on.strftime("%-d %B %Y")}, so it stopped being checked against the " \
            "organisation that day. Restore it to check it again." }
  end

  # An archived plan's checks return early, before the query that would refuse
  # an unknown scenario, so they refuse it here instead.
  #
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String]
  # @raise [Operations::Base::ParameterError] "This plan has no such scenario" unless it is the plan's baseline or one of its scenarios
  def known_scenario!(plan, scenario_id)
    return if scenario_id == plan.id || TeamPlanningScenario.exists?(plan_id: plan.id, id: scenario_id)

    raise Operations::Base::ParameterError, "This plan has no such scenario"
  end

  # @param plan [TeamPlanningPlan]
  # @return [Hash] `{ archived_on, frozen_on, note }` for an archived plan, else empty
  def priced_as_archived(plan)
    return {} unless plan.archived?

    day = plan.archived_on.strftime("%-d %B %Y")
    frozen_on = ::TeamPlanning::PricingInputs.for(plan).frozen_on
    return { archived_on: plan.archived_on.iso8601, frozen_on: frozen_on.iso8601, note: priced_on(day) } if frozen_on

    { archived_on: plan.archived_on.iso8601,
      note: "This plan was archived on #{day}. Its figures still use today's pay bands, exchange rates, budget lines and rules." }
  end

  def priced_on(day)
    "Priced as on #{day}, when this plan was archived: pay bands, exchange rates, budget lines and rules as they stood then. " \
      "Framework roles and levels are read as they are now."
  end

  # @param may [Symbol] the {PlanPolicy} question, `:update?` for a write that checks before its handler does
  # @return [TeamPlanningPlan]
  # @raise [Operations::Base::ParameterError] "No such plan" unless the caller is a member, or may do what `may` asks
  def plan!(may = :show?)
    plan = TeamPlanningPlan.includes(:members).find_by(id: plan_id!)
    return plan if plan && PlanPolicy.new(context, plan).public_send(may)

    raise Operations::Base::ParameterError, "No such plan"
  end
end
