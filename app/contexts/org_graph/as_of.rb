# frozen_string_literal: true

# The roster, the structure and the memberships in effect on one day, read
# from {OrgFactPeriod}. By default it reads what the Org Graph knows now, so
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
# a person on the roster, in a live unit. Leaving writes no ownership event,
# so a leaver who owned a unit drops out of its owners here.
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
  Snapshot = Data.define(:date, :known_on, :people, :units, :memberships)

  # One person's facts that day, and who supplied each, keyed by fact
  # ("title", "site", "employment", …).
  Person = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type, :providers)

  # One live unit that day. `parent_id` is nil at the root.
  Unit = Data.define(:id, :name, :parent_id, :level_id, :owner_ids)

  # A person's place in a unit that day.
  Membership = Data.define(:person_id, :unit_id, :allocation, :role)

  # @param context [AuthorizationContext]
  # @param date [Date] the day to read
  # @param known_on [Date, nil] read what was known at the end of this day
  def initialize(context:, date:, known_on: nil)
    @context = context
    @date = date
    @known_on = known_on
  end

  # @return [Snapshot]
  # @raise [Pundit::NotAuthorizedError] when the caller can't see the Org Graph
  def call
    Pundit.authorize(@context, :org_graph, :show?)

    rows = periods.group_by(&:subject_type)
    people = people_from(rows.fetch(OrgGraph::Projections::History::PERSON, []))
    units = units_from(rows.fetch(OrgGraph::Projections::History::UNIT, []), people.to_set(&:id))
    memberships = memberships_from(rows.fetch(OrgGraph::Projections::History::PERSON, []),
                                   people.to_set(&:id), units.to_set(&:id))
    Snapshot.new(date: @date, known_on: @known_on, people:, units:, memberships:)
  end

  Row = Data.define(:subject_type, :subject_id, :fact, :key, :value, :provider)
  private_constant :Row

  private

  def periods
    knowledge = @known_on ? OrgFactPeriod.known_at(@known_on.in_time_zone("UTC").end_of_day) : OrgFactPeriod.current
    day = knowledge.in_effect_on(@date)
    day.where(subject_type: OrgGraph::Projections::History::PERSON, fact: PERSON_FACTS + %w[membership])
      .or(day.where(subject_type: OrgGraph::Projections::History::UNIT, fact: UNIT_FACTS))
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

  def units_from(rows, person_ids)
    rows.group_by(&:subject_id).filter_map do |id, facts|
      owners, facts = facts.partition { it.fact == "owner" }
      by_fact = facts.index_by(&:fact)
      value = ->(fact, field) { by_fact[fact]&.value&.fetch(field, nil) }
      next unless value.("status", "status") == "live"

      owner_ids = owners.select { it.value && person_ids.include?(it.key) }.map(&:key).sort
      Unit.new(id:, name: value.("name", "name"), parent_id: value.("parent", "parent_id"),
               level_id: value.("level", "level_id"), owner_ids:)
    end.sort_by { [ it.name.to_s, it.id ] }
  end

  def memberships_from(rows, person_ids, unit_ids)
    rows.select { it.fact == "membership" && it.value && person_ids.include?(it.subject_id) && unit_ids.include?(it.key) }
      .map { Membership.new(person_id: it.subject_id, unit_id: it.key, allocation: it.value["allocation"], role: it.value["role"]) }
      .sort_by { [ it.unit_id, it.person_id ] }
  end
end
