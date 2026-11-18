# frozen_string_literal: true

# The roster, the structure, its kinds of unit and the memberships in effect
# on one day, read from {OrgFactPeriod}. By default it reads what the Org Graph knows now, so
# a later day includes the changes already recorded for it: a hire who
# starts then, a move or a leaving scheduled for it. With `known_on` it reads
# what the Org Graph knew at the end of that day (UTC), so a correction
# learned since is left out.
#
# Everyone is named by id. Callers join names, so a forgotten person reads as
# a former member wherever they appear. A unit's name is the exception: the
# structure events carry it.
#
# Memberships and owners are kept only where both ends are in the snapshot:
# a person on the roster, in a live unit. The units retired by the day, and
# the successions recorded by then, are held apart from the live units, and
# the people who had left by the day from the roster.
# Leaving writes no ownership event, so a leaver who owned a unit drops out of
# its owners here.
#
# @example
#   snapshot = OrgGraph::AsOf.new(context:, date: Date.new(2026, 7, 1)).call
#   snapshot.units.map(&:name)
#   snapshot.memberships.select { it.unit_id == payments_id }.map(&:person_id)
class OrgGraph::AsOf
  PERSON_FACTS = %w[employment_status title level manager cost_centre site employment].freeze
  UNIT_FACTS = %w[name parent level status owner].freeze

  # What one day looked like.
  #
  # @!attribute date [Date]
  # @!attribute known_on [Date, nil] nil for what the Org Graph knows now
  # @!attribute people [Array<Person>] the people employed that day, by id
  # @!attribute units [Array<Unit>] the live units, by name
  # @!attribute memberships [Array<Membership>]
  # @!attribute retired_units [Array<Unit>] the units retired by that day, as they last stood, by name
  # @!attribute successions [Array<Succession>] the successions recorded by that day, by id
  # @!attribute left_ids [Array<String>] the people who had left by that day, by id
  # @!attribute kinds [Array<OrgGraph::Taxonomy::Kind>] the top structure's
  #   kinds of unit and where each could sit, top first
  # @!attribute structures [Hash{String => Array<OrgGraph::Taxonomy::Kind>}]
  #   each structure a unit declared, keyed by that unit's id, its kinds top first
  Snapshot = Data.define(:date, :known_on, :people, :units, :memberships, :retired_units, :successions, :left_ids, :kinds,
                         :structures)

  # One person's facts that day, and who supplied each, keyed by fact
  # ("title", "site", "employment", …).
  Person = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type, :providers)

  # One live unit that day. `parent_id` is nil at the root.
  Unit = Data.define(:id, :name, :parent_id, :level_id, :owner_ids)

  # A person's place in a unit that day.
  Membership = Data.define(:person_id, :unit_id, :allocation, :role)

  # Which units carry on from which, each side sorted.
  Succession = Data.define(:id, :predecessor_ids, :successor_ids)

  # @param context [AuthorizationContext]
  # @param date [Date] the day to read
  # @param known_on [Date, nil] read what was known at the end of this day
  # @param known_at [Time, nil] the instant `known_on` ended, when the reader fixed it
  def initialize(context:, date:, known_on: nil, known_at: nil)
    @context = context
    @date = date
    @known_on = known_on
    @known_at = known_at
  end

  # @return [Snapshot]
  # @raise [Pundit::NotAuthorizedError] when the caller can't see the Org Graph
  def call
    Pundit.authorize(@context, :org_graph, :show?)

    rows = periods.group_by(&:subject_type)
    people = people_from(rows.fetch(OrgGraph::Projections::History::PERSON, []))
    person_ids = people.to_set(&:id)
    units = units_from(rows.fetch(OrgGraph::Projections::History::UNIT, []), person_ids)
    live = units.fetch("live", [])
    memberships = memberships_from(rows.fetch(OrgGraph::Projections::History::PERSON, []), person_ids, live.to_set(&:id))
    Snapshot.new(date: @date, known_on: @known_on, people:, units: live, memberships:, retired_units: units.fetch("retired", []),
                 successions: successions_from(rows.fetch(OrgGraph::Projections::History::SUCCESSION, [])),
                 left_ids: left_from(rows.fetch(OrgGraph::Projections::History::PERSON, [])),
                 **kinds_by_structure(rows.fetch(OrgGraph::Projections::History::LEVEL, [])))
  end

  Row = Data.define(:subject_type, :subject_id, :fact, :key, :value, :provider)
  private_constant :Row

  private

  def periods
    day = OrgFactPeriod.known_on(@known_on, at: @known_at).in_effect_on(@date)
    day.where(subject_type: OrgGraph::Projections::History::PERSON, fact: PERSON_FACTS + %w[membership])
      .or(day.where(subject_type: OrgGraph::Projections::History::UNIT, fact: UNIT_FACTS))
      .or(day.where(subject_type: OrgGraph::Projections::History::SUCCESSION, fact: "succession"))
      .or(day.where(subject_type: OrgGraph::Projections::History::LEVEL, fact: "kind"))
      .pluck(:subject_type, :subject_id, :fact, :key, :value, :provider)
      .map { Row.new(*it) }
  end

  def people_from(rows)
    rows.reject { it.fact == "membership" }.group_by(&:subject_id).filter_map do |id, facts|
      by_fact = facts.index_by(&:fact)
      next unless by_fact["employment_status"]&.value&.fetch("employment_status", nil) == "employed"

      value = ->(fact, field) { by_fact[fact]&.value&.fetch(field, nil) }
      Person.new(id:, title: value.("title", "title"), level: value.("level", "level"),
                 manager_id: value.("manager", "manager_id"), cost_centre: value.("cost_centre", "cost_centre"),
                 site: value.("site", "site"), country: value.("site", "country"), fte: value.("employment", "fte"),
                 employment_type: value.("employment", "employment_type"),
                 providers: facts.reject { it.fact == "employment_status" }.to_h { [ it.fact, it.provider ] })
    end.sort_by(&:id)
  end

  # @return [Hash{String => Array<Unit>}] by status
  def units_from(rows, person_ids)
    rows.group_by(&:subject_id).map do |id, facts|
      owners, facts = facts.partition { it.fact == "owner" }
      by_fact = facts.index_by(&:fact)
      value = ->(fact, field) { by_fact[fact]&.value&.fetch(field, nil) }

      owner_ids = owners.select { it.value && person_ids.include?(it.key) }.map(&:key).sort
      [ value.("status", "status"), Unit.new(id:, name: value.("name", "name"), parent_id: value.("parent", "parent_id"),
                                             level_id: value.("level", "level_id"), owner_ids:) ]
    end.group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort_by { [ it.name.to_s, it.id ] } }
  end

  def left_from(rows)
    rows.select { it.fact == "employment_status" && it.value&.fetch("employment_status", nil) == "left" }.map(&:subject_id).uniq.sort
  end

  def successions_from(rows)
    rows.filter_map do |row|
      next unless row.value

      Succession.new(id: row.subject_id, predecessor_ids: row.value["predecessor_ids"].sort, successor_ids: row.value["successor_ids"].sort)
    end.sort_by(&:id)
  end

  def kinds_by_structure(rows)
    structures = rows.select(&:value).group_by { it.value["structure_unit_id"] }.transform_values { kinds_from(it) }
    { kinds: structures.delete(nil) || [], structures: structures.sort.to_h }
  end

  def kinds_from(rows)
    rows = rows.sort_by { it.value["position"] }
    levels = rows.map { { level_id: it.subject_id, **it.value.symbolize_keys.slice(:name, :parent_level_ids, :top) } }
    OrgGraph::Taxonomy.new(levels, providers: rows.to_h { [ it.subject_id, it.value["provider"] ] }).kinds
  end

  def memberships_from(rows, person_ids, unit_ids)
    rows.select { it.fact == "membership" && it.value && person_ids.include?(it.subject_id) && unit_ids.include?(it.key) }
      .map { Membership.new(person_id: it.subject_id, unit_id: it.key, allocation: it.value["allocation"], role: it.value["role"]) }
      .sort_by { [ it.unit_id, it.person_id ] }
  end
end
