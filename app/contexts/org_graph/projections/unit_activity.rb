# frozen_string_literal: true

# Synchronous projection of each unit's activity: the changes to the unit
# itself and to its memberships, from the structure and person streams.
#
# Writes `org_unit_activities`, and nothing else writes it. Rows are only ever
# added, except that an entry someone changes back is marked with the change
# that undid it. Entries sort by the event's global position, so they keep the
# order the Org Graph learned them in. A membership's earlier terms come from
# this projection's own rows, so a rebuild reads them as they stood.
#
class OrgGraph::Projections::UnitActivity
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/unit_activity"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 2

  ACTOR_KEYS = %i[created_by_id renamed_by_id moved_by_id retired_by_id stated_by_id added_by_id removed_by_id
                  set_by_id ended_by_id].freeze
  private_constant :ACTOR_KEYS

  # @return [Array<Class>]
  def self.handled_events
    [
      OrgGraph::Events::UnitCreated, OrgGraph::Events::UnitRenamed, OrgGraph::Events::UnitMoved,
      OrgGraph::Events::UnitRetired, OrgGraph::Events::UnitSucceeded, OrgGraph::Events::UnitOwnerAdded,
      OrgGraph::Events::UnitOwnerRemoved, OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded,
      OrgGraph::Events::MembershipMoved
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { OrgUnitActivity.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      position = Rails.configuration.event_store.global_position(event.event_id)
      entries(event, event.data, position).each { |unit_id, attributes| record(event, position, unit_id, attributes) }
      mark_changed_back(event)
    end
  end

  private

  def entries(event, data, position)
    case event
    when OrgGraph::Events::UnitCreated
      [ [ data[:unit_id], { after: data.slice(:name, :parent_id, :level_id) } ] ]
    when OrgGraph::Events::UnitRenamed
      [ [ data[:unit_id], { subject: "name", before: { name: data[:previous_name] }, after: data.slice(:name) } ] ]
    when OrgGraph::Events::UnitMoved
      [ [ data[:unit_id], { subject: "parent", before: { parent_id: data[:previous_parent_id] },
                            after: data.slice(:parent_id) } ] ]
    when OrgGraph::Events::UnitRetired
      [ [ data[:unit_id], { after: data.slice(:succession_id, :successor_ids) } ] ]
    when OrgGraph::Events::UnitSucceeded then succession_entries(data)
    when OrgGraph::Events::UnitOwnerAdded
      [ [ data[:unit_id], owner(data, after: { owner: true }) ] ]
    when OrgGraph::Events::UnitOwnerRemoved
      [ [ data[:unit_id], owner(data, before: { owner: true }) ] ]
    when OrgGraph::Events::MembershipSet
      [ [ data[:unit_id], membership(data, data[:unit_id], position, after: terms(data)) ] ]
    when OrgGraph::Events::MembershipEnded
      [ [ data[:unit_id], membership(data, data[:unit_id], position, after: nil) ] ]
    when OrgGraph::Events::MembershipMoved
      [ [ data[:from_unit_id], membership(data, data[:from_unit_id], position, after: nil, other_unit_id: data[:unit_id]) ],
        [ data[:unit_id], membership(data, data[:unit_id], position, after: terms(data), other_unit_id: data[:from_unit_id]) ] ]
    end
  end

  def succession_entries(data)
    after = data.slice(:predecessor_ids, :successor_ids)
    (data[:predecessor_ids] + data[:successor_ids]).uniq.map { |unit_id| [ unit_id, { after: after } ] }
  end

  def owner(data, **values)
    { subject: "owner:#{data[:person_id]}", person_id: data[:person_id], **values }
  end

  def membership(data, unit_id, position, after:, other_unit_id: nil)
    subject = "membership:#{data[:person_id]}"
    { subject:, person_id: data[:person_id], other_unit_id:, before: terms_before(unit_id, subject, position), after: }
  end

  def terms(data) = data.slice(:allocation, :role)

  def terms_before(unit_id, subject, position)
    OrgUnitActivity.where(unit_id:, subject:, position: ...position).order(position: :desc).pick(:after)
  end

  def record(event, position, unit_id, attributes)
    data = event.data
    row = OrgUnitActivity.find_or_initialize_by(event_id: event.event_id, unit_id: unit_id)
    row.update!(
      event_type: event.class.name.demodulize,
      position:,
      actor_id: data.values_at(*ACTOR_KEYS).compact.first,
      provider: data[:provider],
      effective_on: data[:effective_on],
      learned_at: event.timestamp,
      causation_id: event.metadata[:causation_id],
      correlation_id: event.metadata[:correlation_id],
      cause_id: event.metadata[:correlation_id] || event.event_id,
      changes_back_id: data[:changed_back_id],
      plan_id: data[:plan_id],
      plan_change_id: data[:plan_change_id],
      **attributes
    )
  end

  def mark_changed_back(event)
    return if event.data[:changed_back_id].blank?

    OrgUnitActivity.where(event_id: event.data[:changed_back_id]).update_all(changed_back_by_id: event.event_id)
  end
end
