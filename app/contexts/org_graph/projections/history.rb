# frozen_string_literal: true

# Synchronous projection of every fact's history with two times: when it took
# effect, and when the Org Graph learned it. Answers "what was true on date X"
# and "what did we know at instant Y" for person facts, memberships,
# structure and ownership.
#
# Writes `org_fact_periods`, and nothing else writes it. Each event revises
# the timelines it touches: the periods it changes are superseded at the
# event's timestamp and their replacements added, so a backdated fact splits
# the periods only for knowledge from then on.
#
# Dates follow the events. A membership's or a unit's end date is its last
# day, and so is a leaving date and an owner's removal, so the period after
# it begins the next day. A move leaves one unit and joins the other on the
# same date. Employment begins on the start date when one is held. A
# change-back dated on the day of the change it reverses withdraws that
# change, as though it never took effect. `PersonForgotten` needs nothing here: the rows hold ids, and the
# history stays.
#
class OrgGraph::Projections::History
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/history"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  PERSON = "person"
  UNIT = "unit"
  SUCCESSION = "succession"

  # The person fact each change event writes, with the fields it holds.
  PERSON_FACTS = {
    OrgGraph::Events::TitleChanged => [ "title", %i[title] ],
    OrgGraph::Events::LevelChanged => [ "level", %i[level] ],
    OrgGraph::Events::ManagerChanged => [ "manager", %i[manager_id] ],
    OrgGraph::Events::CostCentreChanged => [ "cost_centre", %i[cost_centre] ],
    OrgGraph::Events::SiteChanged => [ "site", %i[site country] ],
    OrgGraph::Events::EmploymentChanged => [ "employment", %i[fte employment_type] ]
  }.freeze

  Point = Struct.new(:from, :value, :provider, :event_id)
  private_constant :Point

  # @return [Array<Class>]
  def self.handled_events
    PERSON_FACTS.keys + [
      OrgGraph::Events::PersonRecorded, OrgGraph::Events::PersonJoined, OrgGraph::Events::PersonLeft,
      OrgGraph::Events::PersonReturned, OrgGraph::Events::StartDateChanged,
      OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded, OrgGraph::Events::MembershipMoved,
      OrgGraph::Events::UnitCreated, OrgGraph::Events::UnitRenamed, OrgGraph::Events::UnitMoved,
      OrgGraph::Events::UnitRetired, OrgGraph::Events::UnitSucceeded,
      OrgGraph::Events::UnitOwnerAdded, OrgGraph::Events::UnitOwnerRemoved
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { OrgFactPeriod.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      OrgFactPeriod.transaction { dup.learn_from(event) unless already_learned?(event) }
    end
  end

  protected

  # One subscriber instance serves every publishing thread, so each event is
  # learned on a copy that holds its state.
  def learn_from(event)
    @event = event
    @data = event.data
    @withdrawing = withdraws_original?
    learn
  end

  private

  def learn
    case @event
    when *PERSON_FACTS.keys then person_fact(*PERSON_FACTS.fetch(@event.class))
    when OrgGraph::Events::PersonRecorded then person_recorded
    when OrgGraph::Events::PersonJoined then person_joined
    when OrgGraph::Events::PersonLeft then person_left
    when OrgGraph::Events::PersonReturned then status { |points| put_status(points, effective_on, "employed") }
    when OrgGraph::Events::StartDateChanged then start_date_changed
    when OrgGraph::Events::MembershipSet then membership(@data[:unit_id], effective_on, terms)
    when OrgGraph::Events::MembershipEnded then membership(@data[:unit_id], effective_on + 1, nil)
    when OrgGraph::Events::MembershipMoved then membership_moved
    when OrgGraph::Events::UnitCreated then unit_created
    when OrgGraph::Events::UnitRenamed then unit_fact("name", effective_on, @data.slice(:name))
    when OrgGraph::Events::UnitMoved then unit_fact("parent", effective_on, @data.slice(:parent_id))
    when OrgGraph::Events::UnitRetired then unit_retired
    when OrgGraph::Events::UnitSucceeded then succession
    when OrgGraph::Events::UnitOwnerAdded then owner(effective_on, { owner: true })
    when OrgGraph::Events::UnitOwnerRemoved then owner(effective_on + 1, nil)
    end
  end

  # ── Person facts ──

  def person_fact(fact, fields)
    revise(PERSON, @data[:person_id], fact) { |points| put(points, effective_on, @data.slice(*fields)) }
  end

  def person_recorded
    PERSON_FACTS.each_value do |fact, fields|
      person_fact(fact, fields) unless @data.values_at(*fields).all?(&:nil?)
    end
    started_on = date(@data[:started_on])
    status do |points|
      case @data[:employment_status]
      when "pending" then put_status(points, effective_on, "pending")
      when "employed" then put_status(points, started_on || effective_on, "employed")
      when "left"
        left_from = @data[:left_on] ? date(@data[:left_on]) + 1 : effective_on
        put_status(points, started_on, "employed") if started_on && started_on < left_from
        put_status(points, left_from, "left")
      end
    end
  end

  def person_joined
    status do |points|
      points.reject! { |point| status_of(point) == "pending" && point.from >= effective_on }
      put_status(points, effective_on, "employed")
    end
  end

  # A second leaving corrects the first, so it replaces the leaving it follows.
  # Whatever the person was after the new date, they have left by then.
  def person_left
    left_from = effective_on + 1
    status do |points|
      points.pop while points.last && status_of(points.last) == "left"
      points.reject! { |point| point.from > left_from }
      put_status(points, left_from, "left") unless status_of(value_point(points, left_from)) == "left"
    end
  end

  # Moves the start of the employment the person is in. A start date before
  # their latest leaving is an earlier spell's, which the return already dates.
  def start_date_changed
    started_on = date(@data[:started_on])
    status do |points|
      next unless points.last && status_of(points.last) == "employed"
      next if points.any? { |point| status_of(point) == "left" && point.from > started_on }

      spell = points.rindex { |point| status_of(point) != "employed" }&.+(1) || 0
      later = points[(spell + 1)..].select { |point| point.from > started_on }
      points.slice!(spell..)
      points.concat(later)
      points.reject! { |point| status_of(point) == "pending" && point.from >= started_on }
      put_status(points, started_on, "employed")
    end
  end

  def status(&) = revise(PERSON, @data[:person_id], "employment_status", &)

  def put_status(points, from, employment_status) = put(points, from, { employment_status: })

  def status_of(point) = point&.value&.fetch("employment_status", nil)

  # ── Memberships ──

  def terms = @data.slice(:allocation, :role)

  def membership(unit_id, from, value)
    revise(PERSON, @data[:person_id], "membership", key: unit_id) { |points| put(points, from, value) }
  end

  def membership_moved
    membership(@data[:from_unit_id], effective_on, nil)
    membership(@data[:unit_id], effective_on, terms)
  end

  # ── Structure ──

  def unit_created
    unit_fact("name", effective_on, @data.slice(:name))
    unit_fact("parent", effective_on, @data.slice(:parent_id))
    unit_fact("level", effective_on, @data.slice(:level_id))
    unit_fact("status", effective_on, { status: "live" })
  end

  def unit_retired
    unit_fact("status", effective_on + 1, { status: "retired", **@data.slice(:succession_id, :successor_ids) })
  end

  def owner(from, value)
    revise(UNIT, @data[:unit_id], "owner", key: @data[:person_id]) { |points| put(points, from, value) }
  end

  def unit_fact(fact, from, value)
    revise(UNIT, @data[:unit_id], fact) { |points| put(points, from, value) }
  end

  def succession
    revise(SUCCESSION, @data[:succession_id], "succession") do |points|
      put(points, effective_on, @data.slice(:predecessor_ids, :successor_ids))
    end
  end

  # ── Timelines ──

  # Yields the timeline the Org Graph now believes for one fact, as points in
  # date order, then writes the periods that changed.
  def revise(subject_type, subject_id, fact, key: "")
    rows = OrgFactPeriod.current.where(subject_type:, subject_id:, fact:, key:).order(:effective_from).to_a
    points = rows.map { |row| Point.new(row.effective_from, row.value, row.provider, row.event_id) }
    points.reject! { |point| point.event_id == @data[:changed_back_id] } if @withdrawing
    yield points

    periods = periods(points)
    stale = rows.reject { |row| periods.delete(signature(row)) }
    supersede(stale)
    insert(periods, subject_type:, subject_id:, fact:, key:)
  end

  # A point on a date replaces any other there, as the later knowledge. A
  # change-back's own point is dropped when withdrawing the change already
  # leaves that value in effect.
  def put(points, from, value)
    value = value&.deep_stringify_keys
    return if @withdrawing && value_point(points, from)&.value == value

    points.reject! { |point| point.from == from }
    points << Point.new(from, value, @data[:provider], @event.event_id)
    points.sort_by!(&:from)
  end

  def value_point(points, day) = points.select { |point| point.from <= day }.max_by(&:from)

  def periods(points)
    points = points.sort_by(&:from)
    points.each_with_index.map do |point, index|
      [ point.from, points[index + 1]&.from, point.value, point.provider, point.event_id ]
    end
  end

  def signature(row) = [ row.effective_from, row.effective_to, row.value, row.provider, row.event_id ]

  def supersede(rows)
    return if rows.empty?

    OrgFactPeriod.where(id: rows.map(&:id))
                 .update_all(superseded_at: @event.timestamp, superseded_by_event_id: @event.event_id)
  end

  def insert(periods, **subject)
    return if periods.empty?

    OrgFactPeriod.insert_all!(periods.map do |from, to, value, provider, event_id|
      { id: SecureRandom.uuid_v7, tenant_id: ActsAsTenant.current_tenant.id, **subject, value:, provider:,
        effective_from: from, effective_to: to, learned_at: @event.timestamp, event_id:,
        learned_by_event_id: @event.event_id }
    end)
  end

  # ── Event ──

  def already_learned?(event)
    OrgFactPeriod.where(learned_by_event_id: event.event_id).or(OrgFactPeriod.where(superseded_by_event_id: event.event_id))
                 .exists?
  end

  def withdraws_original?
    return false if @data[:changed_back_id].blank?

    original = Rails.configuration.event_store.read.event(@data[:changed_back_id])
    original.data[:effective_on] == @data[:effective_on]
  rescue RubyEventStore::EventNotFound
    false
  end

  def effective_on = date(@data[:effective_on])

  def date(value) = value.presence && Date.iso8601(value.to_s)
end
