# frozen_string_literal: true

# What changed in the Org Graph between two days, read through
# {OrgGraph::ChangesBetween}. People and units come back as ids only;
# callers join names.
#
# Incremental disclosure: defaults to `summary` (a count per kind). Pass
# `mode: "full"` for every change.
class Operations::OrgGraph::ChangesBetween < Operations::Base
  include Operations::OrgGraph::DateParameter

  description "What changed in the Org Graph between two UTC dates: joiners, leavers, person " \
              "fact changes (title, level, manager, cost centre, site, employment), memberships " \
              "started, ended or changed, moves between units, and units created, renamed, moved, " \
              "retired, succeeded or re-owned. by \"effective\" (the default) lists what took " \
              "effect after from, up to and including to; known_on reads what the Org Graph knew " \
              "at the end of that date. by \"learned\" lists what the Org Graph learned in that " \
              "window whatever date it took effect, so backdated corrections show, and a change it " \
              "no longer believes comes back withdrawn. A change's effective_on is the first day " \
              "it holds, so a leaving dated 30 April shows on 1 May. Defaults to a count per kind; " \
              "mode \"full\" lists every change. People are named by id only."
  category :read
  approval :none

  parameter :from, String, required: true, allow_blank: false,
    schema: DATE_SCHEMA.merge(description: "UTC date, YYYY-MM-DD. The day before the window opens.")
  parameter :to, String, required: true, allow_blank: false,
    schema: DATE_SCHEMA.merge(description: "UTC date, YYYY-MM-DD. The window's last day.")
  parameter :by, String, required: false, allowed: %w[effective learned]
  parameter :known_on, String, required: false, allow_blank: false,
    schema: DATE_SCHEMA.merge(description: "UTC date, YYYY-MM-DD. By effective date only; omit for what is known now.")
  parameter :mode, String, required: false, allowed: %w[summary full]
  forbids_when :known_on, if: :by, equals: "learned"

  # @raise [Pundit::NotAuthorizedError] when the caller isn't a member of the tenant
  def policy_check
    authorize :org_graph, :show?
  end

  # @return [Hash] `:from`, `:to`, `:by`, `:known_on`, `:counts` (changes
  #   per kind, every kind listed) and `:fact_counts` (fact changes per
  #   fact); in full mode also `:changes`, in effective date order
  # @raise [Operations::Base::ParameterError] for a malformed date, a `to`
  #   before `from`, or `known_on` by learned date
  def perform
    result = changes
    payload = {
      from: result.from.iso8601,
      to: result.to.iso8601,
      by: result.by.to_s,
      known_on: result.known_on&.iso8601,
      counts: ::OrgGraph::ChangesBetween::KINDS.index_with { 0 }.merge(result.changes.map(&:kind).tally),
      fact_counts: result.changes.select { it.kind == :fact_changed }.map(&:fact).tally
    }
    return payload unless params[:mode] == "full"

    payload.merge(changes: result.changes.map { serialize(it) })
  end

  private

  def changes
    ::OrgGraph::ChangesBetween.new(context:, from: parse_date(:from), to: parse_date(:to),
                                   by: (params[:by].presence || "effective").to_sym, known_on: parse_date(:known_on)).call
  rescue ArgumentError => e
    raise ParameterError, e.message
  end

  def serialize(change)
    change.to_h.merge(kind: change.kind.to_s, effective_on: change.effective_on.iso8601,
                      learned_at: change.learned_at&.utc&.iso8601)
  end
end
