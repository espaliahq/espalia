# frozen_string_literal: true

# A budget line as a scenario holds it: a tenant line the plan changes, or a
# line the plan adds under an id it minted. The amount seals under the plan's
# key, so deleting the plan shreds it. It shares its facet with
# {BudgetLineCut}, so whichever came last wins: a line set again after a cut
# comes back.
#
# A change to a tenant line the tenant later removes stays in the plan and
# reads as orphaned, never dropped, so Attention can flag it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the tenant line's id, or an id the plan minted
#   @option data [Boolean] :tenant_line whether it changes one of the tenant's lines
#   @option data [Shreddable::Value, nil] :amount the amount as a decimal string, absent with only a head count
#   Plus the rest of {TeamPlanning::Baseline::BUDGET_FIGURES}, dates as ISO strings, and
#   {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::BudgetLineSet < TeamPlanning::Events::Change
  extend Shreddable
  extend TeamPlanning::Events::SealedChange

  shreddable :amount, by: :plan

  # @return [String]
  def self.facet = "budget_line"

  # Holds a plan's line to the rules a tenant's line follows.
  #
  # @param end_state [Hash] the line's figures, as {::BudgetLine} names them, and `tenant_line:`
  # @return [Hash] the figures that are set, dates and decimals as strings
  # @raise [TeamPlanning::Error] with the line's first broken rule
  def self.end_state(end_state)
    end_state = end_state.to_h.symbolize_keys
    line = ::BudgetLine.new(end_state.slice(*TeamPlanning::Baseline::BUDGET_FIGURES))
    line.validate
    broken = line.errors.find { it.attribute != :tenant } and raise TeamPlanning::Error, broken.full_message

    figures = TeamPlanning::Baseline::BUDGET_FIGURES.to_h { [ it, line.public_send(it) ] }
    figures.merge(starts_on: line.starts_on.iso8601, ends_on: line.ends_on.iso8601, approved_on: line.approved_on&.iso8601,
                  amount: line.figure(:amount), head_count: line.figure(:head_count))
           .compact_blank.merge(tenant_line: end_state[:tenant_line] == true)
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    id = data[:subject_id]
    held = map.line?(id)
    if data[:tenant_line] && !held
      # A removed line the plan never held stays unnamed ([#378](https://github.com/espaliahq/espalia/issues/378)).
      return map unless map.holds_cost_centre?(data[:cost_centre])

      return map.with(orphaned_lines: map.orphaned_lines.merge(id => "set"))
    end

    line = TeamPlanning::Baseline::BudgetLine.planned(id, data, source: data[:tenant_line] ? "changed" : "plan")
    return map.with(outside_lines: map.outside_lines.map { it.id == id ? line : it }) if map.outside_line?(id)

    map.with(budget_lines: held ? map.budget_lines.map { it.id == id ? line : it } : map.budget_lines + [ line ])
  end

  # Reads as an override row stores the end state: figures as strings, and the sealed amount left out.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil]
  def self.read_from(map, subject_id:, facet: self.facet)
    line = map.budget_lines.find { it.id == subject_id } or return nil

    (TeamPlanning::Baseline::BUDGET_FIGURES - [ :amount ]).to_h { [ it, line.public_send(it) ] }
      .merge(%i[starts_on ends_on approved_on].to_h { [ it, line.public_send(it)&.iso8601 ] },
             head_count: ::BudgetLine.figure_of(line.head_count))
      .compact_blank.merge(tenant_line: line.source != "plan")
  end
end
