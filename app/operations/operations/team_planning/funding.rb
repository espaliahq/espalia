# frozen_string_literal: true

# Which budget lines each position in a scenario draws on, through
# {TeamPlanning::Funding} ([#345](https://github.com/espaliahq/espalia/issues/345)).
# It reads the scenario's resolved positions, so its totals match what
# team_planning_cost prices. It names no person, but a position's location
# is an occupant's country, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Funding < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::CostFigures

  description "Get which budget lines each open position in a scenario of a Team Planning plan the caller is in draws " \
              "on. A position draws on the most specific line that matches it: the line's cost_centre is the " \
              "position's (as team_planning_cost resolves it), its period overlaps the days the position is held, and " \
              "each of role, level and location the line states is the position's (location is an occupant's " \
              "country, else that of the person it replaces). A line with no cost centre matches any position and is " \
              "the least specific; past that, the more of role, level and location a line states, the more specific. " \
              "source is 'derived', or 'set' by team_planning_set_position_funding, which wins. A position is " \
              "unfunded with a reason: no_line, ambiguous (matching_ids lists the lines that tie; none is picked) or " \
              "line_gone (its funding names a line the scenario no longer holds). Each line lists its positions in " \
              "draw order, filled first, then open positions replacing a leaver, then other open positions, each by " \
              "starts_on then id, with draw_reason saying which. Totals count positions and FTE: funded counts the " \
              "positions funded whole and the FTE every draw funds, and funded plus unfunded is always the total. " \
              "FTE and shares are decimal strings. The baseline has no period, so it can't be the scenario. " \
              "Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan; not the plan's id, as the baseline has no period." }

  # @return [Hash] `{ plan_id, scenario_id, period, total, funded, unfunded, positions, budget_lines }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::Funding.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, period: { starts_on: report.period.begin.iso8601, ends_on: report.period.end.iso8601 },
      total: count(report.total), funded: count(report.funded), unfunded: count(report.unfunded),
      positions: report.positions.map { position(it) },
      budget_lines: report.by_line.sort.map { |budget_line_id, draws| { budget_line_id:, positions: draws.map { drawn(*it) } } } }
  end

  private

  def count(count) = { positions: count.positions, fte: decimal(count.fte) }

  def position(funded)
    { position_id: funded.position.id, unit_id: funded.position.unit_id, fte: decimal(funded.fte),
      cost_centre: funded.cost_centre.cost_centre, cost_centre_source: funded.cost_centre.source, location: funded.location,
      draw_reason: funded.draw_reason, starts_on: funded.starts_on.iso8601, source: funded.source,
      state: funded.funded? ? "funded" : "unfunded", reason: funded.reason,
      reason_text: funded.reason && ::TeamPlanning::Funding::REASONS.fetch(funded.reason),
      draws: funded.draws.map { { budget_line_id: it.budget_line_id, share: decimal(it.share), held: it.held } },
      matching_ids: funded.matching_ids }
  end

  def drawn(funded, draw)
    { position_id: funded.position.id, share: decimal(draw.share), fte: decimal(funded.fte * draw.share),
      draw_reason: funded.draw_reason, starts_on: funded.starts_on.iso8601 }
  end
end
