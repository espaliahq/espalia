# frozen_string_literal: true

# Synchronous projection of a tenant's current structure: its taxonomy levels
# and its unit tree.
#
# Writes `org_taxonomy_levels`, `org_units` and `org_unit_successions`, and
# nothing else writes them. The level and unit primary keys are event-carried
# ids, so references survive a rebuild.
# A level's effective_on is the date its name or place last changed.
#
class OrgGraph::Projections::Structure
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/structure"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    [
      OrgGraph::Events::TaxonomyDefined,
      OrgGraph::Events::UnitCreated,
      OrgGraph::Events::UnitRenamed,
      OrgGraph::Events::UnitMoved,
      OrgGraph::Events::UnitRetired,
      OrgGraph::Events::UnitSucceeded
    ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      OrgUnitSuccession.where(tenant_id: tenant.id).delete_all
      OrgUnit.where(tenant_id: tenant.id).delete_all
      OrgTaxonomyLevel.where(tenant_id: tenant.id).delete_all
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) { handle(event) }
  end

  private

  def handle(event)
    case event
    when OrgGraph::Events::TaxonomyDefined then handle_taxonomy_defined(event.data)
    when OrgGraph::Events::UnitCreated then handle_unit_created(event.data)
    when OrgGraph::Events::UnitRenamed then update_unit(event.data, name: event.data[:name], name_effective_on: event.data[:effective_on])
    when OrgGraph::Events::UnitMoved then update_unit(event.data, parent_id: event.data[:parent_id], parent_effective_on: event.data[:effective_on])
    when OrgGraph::Events::UnitRetired then update_unit(event.data, retired_on: event.data[:effective_on])
    when OrgGraph::Events::UnitSucceeded then handle_unit_succeeded(event.data)
    end
  end

  # Positions are cleared first so a reorder can't trip the unique index.
  def handle_taxonomy_defined(data)
    levels = data[:levels].map { |level| level.to_h.symbolize_keys }
    existing = OrgTaxonomyLevel.where(tenant_id: ActsAsTenant.current_tenant.id)
    existing.where.not(id: levels.pluck(:level_id)).delete_all
    existing.update_all("position = -position - 1")

    levels.each.with_index do |level, position|
      row = OrgTaxonomyLevel.find_or_initialize_by(id: level[:level_id])
      unchanged = row.persisted? && row.name == level[:name] && row.position == -position - 1
      row.assign_attributes(name: level[:name], position: position)
      row.effective_on = data[:effective_on] unless unchanged
      row.save!
    end
  end

  def handle_unit_created(data)
    unit = OrgUnit.find_or_initialize_by(id: data[:unit_id])
    unit.update!(
      name: data[:name],
      name_effective_on: data[:effective_on],
      parent_id: data[:parent_id],
      parent_effective_on: data[:effective_on],
      level_id: data[:level_id],
      provider: data[:provider],
      external_ref: data[:external_ref],
      created_on: data[:effective_on],
      retired_on: nil
    )
  end

  def handle_unit_succeeded(data)
    data[:predecessor_ids].product(data[:successor_ids]).each do |predecessor_id, successor_id|
      OrgUnitSuccession.find_or_create_by!(succession_id: data[:succession_id], predecessor_id:, successor_id:) do |link|
        link.effective_on = data[:effective_on]
      end
    end
  end

  def update_unit(data, **attributes)
    OrgUnit.find(data[:unit_id]).update!(attributes)
  end
end
