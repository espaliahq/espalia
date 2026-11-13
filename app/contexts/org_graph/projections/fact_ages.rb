# frozen_string_literal: true

# Synchronous projection of when each fact Espalia holds about a person was
# last changed or confirmed, from the person streams.
#
# Writes `org_fact_ages`, and nothing else writes it. A fact moves to another
# provider or is cleared, and its row goes. Ages run from when the Org Graph
# learned of a change, the event's own timestamp, so a backdated fact does not
# arrive already stale. A leaver is marked by a row whose fact is "left", so a
# fact Espalia writes for them later still reads as a leaver's.
#
class OrgGraph::Projections::FactAges
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/fact_ages"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before. That includes a change to {PERSON_FACTS}.
  CODE_VERSION = 1

  # The person facts it ages. Its own list, so a fact the aggregate gains is
  # aged only once someone adds it here and bumps {CODE_VERSION}.
  PERSON_FACTS = %i[title level manager_id cost_centre site country fte employment_type].freeze
  LEFT = "left"

  FACT_EVENTS = [
    OrgGraph::Events::PersonRecorded, OrgGraph::Events::TitleChanged, OrgGraph::Events::LevelChanged,
    OrgGraph::Events::ManagerChanged, OrgGraph::Events::CostCentreChanged, OrgGraph::Events::SiteChanged,
    OrgGraph::Events::EmploymentChanged
  ].freeze
  private_constant :FACT_EVENTS

  # @return [Array<Class>]
  def self.handled_events
    FACT_EVENTS + [
      OrgGraph::Events::PersonLeft, OrgGraph::Events::PersonJoined, OrgGraph::Events::PersonReturned,
      OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded, OrgGraph::Events::MembershipMoved,
      OrgGraph::Events::FactConfirmed
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { OrgFactAge.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      case event
      when *FACT_EVENTS then handle_facts(event)
      when OrgGraph::Events::PersonLeft then mark_left(event)
      when OrgGraph::Events::PersonJoined, OrgGraph::Events::PersonReturned then rows(event, LEFT).delete_all
      when OrgGraph::Events::MembershipSet then handle_membership_set(event)
      when OrgGraph::Events::MembershipEnded then rows(event, membership, event.data[:unit_id]).delete_all
      when OrgGraph::Events::MembershipMoved then handle_membership_moved(event)
      when OrgGraph::Events::FactConfirmed then handle_confirmed(event)
      end
    end
  end

  private

  def membership = OrgGraph::FactConfirmation::MEMBERSHIP

  def handle_facts(event)
    data = event.data
    mark_left(event) if event.is_a?(OrgGraph::Events::PersonRecorded) && data[:employment_status] == "left"

    given = PERSON_FACTS.select { |key| data.key?(key) }
    held = data[:provider] == "espalia" ? given.reject { |key| data[key].nil? } : []
    rows(event, (given - held).map(&:to_s)).delete_all if given != held
    held.each { |key| changed(event, key.to_s, nil, data[key], checked_by_id: nil) }
  end

  def handle_membership_set(event)
    data = event.data
    return rows(event, membership, data[:unit_id]).delete_all unless data[:provider] == "espalia"

    changed(event, membership, data[:unit_id], data.slice(:allocation, :role), checked_by_id: data[:set_by_id])
  end

  # A move places the person in a unit nobody has confirmed them in yet, so
  # its age starts again there.
  def handle_membership_moved(event)
    data = event.data
    rows(event, membership, data[:from_unit_id]).delete_all
    return unless data[:provider] == "espalia"

    changed(event, membership, data[:unit_id], data.slice(:allocation, :role), checked_by_id: data[:moved_by_id])
  end

  def handle_confirmed(event)
    data = event.data
    rows(event, data[:fact], data[:unit_id]).update_all(
      confirmed_at: event.timestamp, checked_at: event.timestamp, checked_by_id: data[:confirmed_by_id],
      updated_at: Time.current
    )
  end

  def mark_left(event)
    OrgFactAge.find_or_initialize_by(person_id: event.data[:person_id], fact: LEFT, unit_id: nil)
      .update!(changed_at: event.timestamp, checked_at: event.timestamp)
  end

  # A pair event names both halves, so an unchanged half keeps its age.
  def changed(event, key, unit_id, value, checked_by_id:)
    row = OrgFactAge.find_or_initialize_by(person_id: event.data[:person_id], fact: key, unit_id: unit_id)
    return if row.persisted? && row.value == value.as_json

    row.update!(value: value, changed_at: event.timestamp, confirmed_at: nil, checked_at: event.timestamp,
      checked_by_id: checked_by_id)
  end

  def rows(event, fact, unit_id = nil)
    OrgFactAge.where(person_id: event.data[:person_id], fact: fact, unit_id: unit_id)
  end
end
