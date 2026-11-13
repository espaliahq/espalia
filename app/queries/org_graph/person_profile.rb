# frozen_string_literal: true

# One person as the Org Graph holds them (#132): their teams, their
# employment facts with the provider that holds each, and the history of both
# from `org_graph/history`, each change with when it took effect and when the
# Org Graph learned it.
#
# A forgotten person keeps their history. Their identity was erased, so their
# name reads as a former member.
class OrgGraph::PersonProfile
  # Employment facts in the order the drawer lists them, with the fields each
  # holds in the history projection.
  EMPLOYMENT = {
    "title" => "Title",
    "level" => "Level",
    "manager" => "Manager",
    "cost_centre" => "Cost centre",
    "site" => "Site",
    "employment" => "Employment"
  }.freeze

  STATUS = "employment_status"
  MEMBERSHIP = "membership"

  # @!attribute fact [String] a key of {EMPLOYMENT}, or "started"
  # @!attribute label [String]
  # @!attribute value [String]
  # @!attribute provider [String]
  # @!attribute since [Date]
  Fact = Data.define(:fact, :label, :value, :provider, :since)

  # @!attribute effective_on [Date] when the change took effect
  # @!attribute learned_at [Time] when the Org Graph learned it
  # @!attribute fact [String]
  # @!attribute key [String] the unit id for a membership, otherwise ""
  # @!attribute summary [String]
  # @!attribute provider [String]
  # @!attribute actor [Person, nil] who made it, when a person did
  Change = Data.define(:effective_on, :learned_at, :fact, :key, :summary, :provider, :actor)

  attr_reader :person

  # @param person [Person]
  # @param today [Date]
  def initialize(person, today: Date.current)
    @person = person
    @today = today
  end

  # @return [Array<OrgMembership>] memberships of live units, by unit name
  def memberships
    @memberships ||= OrgMembership.in_live_units.where(person_id: person.id).includes(:unit)
                                  .sort_by { |membership| membership.unit.name.downcase }
  end

  # @return [Array<Fact>] the employment facts in effect today, then the start date
  def employment
    @employment ||= begin
      facts = EMPLOYMENT.filter_map do |fact, label|
        row = in_effect(fact)
        next unless row && described(fact, row.value)

        Fact.new(fact:, label:, value: described(fact, row.value), provider: row.provider, since: row.effective_from)
      end
      facts + [ started ].compact
    end
  end

  # @return [Array<Change>] newest first
  def history
    @history ||= begin
      changes = timeline.flat_map do |(fact, key), periods|
        periods.each_with_index.filter_map do |row, index|
          summary = change_summary(fact, key, index.zero? ? nil : periods[index - 1].value, row.value)
          next unless summary

          change = Change.new(effective_on: effective_on(row), learned_at: learned_at(row), fact:, key:, summary:,
                              provider: row.provider, actor: actors[row.event_id])
          [ change, row.id ]
        end
      end
      # Ids are time-ordered, so they break a tie in the order the projection wrote the rows.
      changes.sort_by { |change, id| [ change.effective_on, change.learned_at, id ] }.reverse.map(&:first)
    end
  end

  # The latest change to a membership, which says who set it as it stands.
  #
  # @param unit_id [String]
  # @return [Change, nil]
  def last_change_to(unit_id) = history.find { |change| change.fact == MEMBERSHIP && change.key == unit_id }

  private

  def periods = @periods ||= OrgFactPeriod.current.where(subject_type: "person", subject_id: person.id).to_a

  # @return [Hash{Array(String, String) => Array<OrgFactPeriod>}] each fact's periods, oldest first
  def timeline = periods.group_by { |row| [ row.fact, row.key ] }.transform_values { |rows| rows.sort_by(&:effective_from) }

  # An ending or a leaving is recorded from the day after the last day, which
  # is the day the person who made it chose. A move ends on the day it takes effect.
  def effective_on(row)
    from_next_day = case (event = events[row.event_id])
    when OrgGraph::Events::MembershipEnded, OrgGraph::Events::PersonLeft then true
    when OrgGraph::Events::PersonRecorded then row.fact == STATUS && event.data[:left_on].present? && status_of(row) == "left"
    end
    from_next_day ? row.effective_from - 1 : row.effective_from
  end

  def status_of(row) = row.value&.fetch("employment_status", nil)

  def in_effect(fact)
    periods.find do |row|
      row.fact == fact && row.effective_from <= @today && (row.effective_to.nil? || row.effective_to > @today)
    end
  end

  # The first day of the spell they are in now; none once they have left.
  def started
    rows = Array(timeline[[ STATUS, "" ]]).select { |row| row.effective_from <= @today }
    return unless rows.last && status_of(rows.last) == "employed"

    row = rows.reverse.take_while { |r| status_of(r) == "employed" }.last

    Fact.new(fact: "started", label: "Started", value: row.effective_from.strftime("%-d %b %Y"),
             provider: row.provider, since: row.effective_from)
  end

  # @return [String, nil] the fact's value in words, nil when it holds none
  def described(fact, value)
    return if value.nil?

    case fact
    when "title" then value["title"]
    when "level" then value["level"]
    when "manager" then value["manager_id"] && name_of(value["manager_id"])
    when "cost_centre" then value["cost_centre"]
    when "site" then value.values_at("site", "country").compact_blank.join(", ").presence
    when "employment" then employment_words(value)
    end
  end

  def employment_words(value)
    fte = value["fte"] && "#{format('%.1f', value['fte'])} FTE"
    [ value["employment_type"]&.humanize, fte ].compact.join(", ").presence
  end

  def change_summary(fact, key, before, after)
    case fact
    when MEMBERSHIP then membership_summary(unit_name(key), before, after)
    when STATUS then status_summary(before, after)
    when *EMPLOYMENT.keys then fact_summary(EMPLOYMENT.fetch(fact), described(fact, before), described(fact, after))
    end
  end

  def fact_summary(label, before, after)
    return if before == after
    return "#{label} #{after.nil? ? 'cleared' : "set to #{after}"}" if before.nil? || after.nil?

    "#{label} changed from #{before} to #{after}"
  end

  def membership_summary(unit, before, after)
    return if before == after
    return "Left #{unit}" if after.nil?
    return "Joined #{unit}#{terms(after)}" if before.nil?

    "In #{unit}#{terms(after).presence || ' as a member'}"
  end

  # @return [String] " as Tech lead at 50%", either part, or ""
  def terms(value)
    role = " as #{value['role']}" if value["role"].present?
    allocation = " at #{(value['allocation'] * 100).round}%" if value["allocation"]
    "#{role}#{allocation}"
  end

  def status_summary(before, after)
    status = after&.fetch("employment_status", nil)
    return if status == before&.fetch("employment_status", nil)

    case status
    when "pending" then "Due to start"
    when "employed" then "Started"
    when "left" then "Left"
    end
  end

  def unit_name(unit_id) = units[unit_id]&.name || "a unit no longer held"

  def units
    @units ||= OrgUnit.where(id: periods.select { |row| row.fact == MEMBERSHIP }.map(&:key)).index_by(&:id)
  end

  def name_of(person_id) = people[person_id]&.name || Person::FORMER_MEMBER

  def people
    @people ||= begin
      ids = periods.filter_map { |row| row.value&.fetch("manager_id", nil) if row.fact == "manager" }
      Person.where(id: ids).index_by(&:id)
    end
  end

  # A row's own learned_at moves when a later event closes its period, so the
  # change was learned when the event that made it was stored.
  def learned_at(row) = events[row.event_id]&.timestamp || row.learned_at

  def events
    @events ||= Rails.configuration.event_store.read.events(periods.map(&:event_id).uniq).index_by(&:event_id)
  end

  # Who made each change, from the events' provenance. A sync or a job has none.
  def actors
    @actors ||= begin
      ids = events.transform_values { |event| event.metadata[:actor_id] }.compact
      people = Person.where(id: ids.values.uniq).index_by(&:id)
      ids.transform_values { |id| people[id] }.compact
    end
  end
end
