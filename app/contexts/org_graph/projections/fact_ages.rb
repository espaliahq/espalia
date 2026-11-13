# frozen_string_literal: true

# Synchronous projection of when each fact Espalia holds about a person was
# last changed or confirmed, from the person streams (#81).
#
# Writes `org_fact_ages`, and nothing else writes it. A fact moves to another
# provider or is cleared, and its row goes. Ages run from when the Org Graph
# learned of the change, the event's own timestamp, so a backdated fact does
# not arrive already stale.
#
class OrgGraph::Projections::FactAges
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/fact_ages"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  FACT_EVENTS = [
    OrgGraph::Events::PersonRecorded, OrgGraph::Events::TitleChanged, OrgGraph::Events::LevelChanged,
    OrgGraph::Events::ManagerChanged, OrgGraph::Events::CostCentreChanged, OrgGraph::Events::SiteChanged,
    OrgGraph::Events::EmploymentChanged
  ].freeze
  STATUS_EVENTS = {
    OrgGraph::Events::PersonLeft => true,
    OrgGraph::Events::PersonJoined => false,
    OrgGraph::Events::PersonReturned => false
  }.freeze
  private_constant :FACT_EVENTS, :STATUS_EVENTS

  # @return [Array<Class>]
  def self.handled_events
    FACT_EVENTS + STATUS_EVENTS.keys + [
      OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded, OrgGraph::Events::FactConfirmed
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
      when *STATUS_EVENTS.keys then for_person(event).update_all(person_left: STATUS_EVENTS.fetch(event.class))
      when OrgGraph::Events::MembershipSet then handle_membership_set(event)
      when OrgGraph::Events::MembershipEnded then fact(event, membership, event.data[:unit_id]).delete_all
      when OrgGraph::Events::FactConfirmed then handle_confirmed(event)
      end
    end
  end

  private

  def membership = OrgGraph::FactConfirmation::MEMBERSHIP

  def person_facts
    OrgGraph::PersonAggregate.confirmable_facts - [ membership ]
  end

  def handle_facts(event)
    data = event.data
    left = data[:employment_status] == "left" if event.is_a?(OrgGraph::Events::PersonRecorded)
    person_facts.each do |key|
      next unless data.key?(key.to_sym)

      if data[:provider] == "espalia" && !data[key.to_sym].nil?
        changed(event, key, nil, checked_by_id: event.metadata[:actor_id], person_left: left)
      else
        fact(event, key, nil).delete_all
      end
    end
  end

  def handle_membership_set(event)
    data = event.data
    return fact(event, membership, data[:unit_id]).delete_all unless data[:provider] == "espalia"

    changed(event, membership, data[:unit_id], checked_by_id: data[:set_by_id] || event.metadata[:actor_id])
  end

  def handle_confirmed(event)
    data = event.data
    fact(event, data[:fact], data[:unit_id]).update_all(
      confirmed_at: event.timestamp, checked_at: event.timestamp, checked_by_id: data[:confirmed_by_id],
      updated_at: Time.current
    )
  end

  def changed(event, key, unit_id, checked_by_id:, person_left: nil)
    row = OrgFactAge.find_or_initialize_by(person_id: event.data[:person_id], fact: key, unit_id: unit_id)
    row.person_left = person_left unless person_left.nil?
    row.update!(changed_at: event.timestamp, confirmed_at: nil, checked_at: event.timestamp,
      checked_by_id: checked_by_id)
  end

  def for_person(event) = OrgFactAge.where(person_id: event.data[:person_id])

  def fact(event, key, unit_id) = for_person(event).where(fact: key, unit_id: unit_id)
end
