# frozen_string_literal: true

# What changed in the Org Graph between two days, read through
# {OrgGraph::ChangesBetween}. People and units come back as ids only;
# callers join names.
#
# Incremental disclosure: defaults to `summary` (a count per kind). Pass
# `mode: "full"` for every change.
class Operations::OrgGraph::ChangesBetween < Operations::Base
  include Operations::OrgGraph::DateParameter

  description "What changed in the Org Graph between two UTC dates: joiners (with every fact " \
              "they hold on their first day), leavers, person " \
              "fact changes (title, level, manager, cost centre, site, employment), memberships " \
              "started, ended or changed, moves between units, and units created, renamed, moved, " \
              "retired, succeeded or re-owned. by \"effective\" (the default) lists what took " \
              "effect after from, up to and including to; known_on reads what the Org Graph knew " \
              "at 23:59:59 UTC on that date, not in the tenant's local time. by \"learned\" lists " \
              "what the Org Graph learned after 23:59:59 UTC on from, up to 23:59:59 UTC on to, " \
              "whatever date it took effect, so backdated corrections show, and a change it " \
              "no longer believes comes back withdrawn. A change's effective_on is the first day " \
              "it holds, so a leaving dated 30 April shows on 1 May. Defaults to a count per kind, " \
              "with withdrawn changes counted apart; mode \"full\" lists every change. People are " \
              "named by id only."
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
  #   per kind, every kind listed), `:withdrawn_counts` (the same for
  #   withdrawn changes) and `:fact_counts` (fact changes per fact, withdrawn
  #   ones left out); in full mode also `:changes`, in effective date order
  # @raise [Operations::Base::ParameterError] for a malformed date, a `to`
  #   before `from`, or `known_on` by learned date
  def perform
    result = reader.call
    withdrawn, held = result.changes.partition(&:withdrawn)
    payload = {
      from: result.from.iso8601,
      to: result.to.iso8601,
      by: result.by.to_s,
      known_on: result.known_on&.iso8601,
      counts: tally(held),
      withdrawn_counts: tally(withdrawn),
      fact_counts: held.select { it.kind == :fact_changed }.map(&:fact).tally
    }
    return payload unless params[:mode] == "full"

    payload.merge(changes: result.changes.map { serialize(it) })
  end

  private

  def reader
    ::OrgGraph::ChangesBetween.new(context:, from: parse_date(:from), to: parse_date(:to),
                                   by: (params[:by].presence || "effective").to_sym, known_on: parse_date(:known_on))
  rescue ArgumentError => e
    raise ParameterError, e.message
  end

  def tally(changes) = ::OrgGraph::ChangesBetween::KINDS.index_with { 0 }.merge(changes.map(&:kind).tally)

  def serialize(change)
    change.to_h.merge(kind: change.kind.to_s, effective_on: change.effective_on.iso8601,
                      learned_at: change.learned_at&.utc&.iso8601)
  end
end
