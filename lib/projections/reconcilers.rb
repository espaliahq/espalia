# frozen_string_literal: true

# Every reconciler predeploy runs, and the projections each one adopts.
#
# A reconciler makes a tenant stream record what its table holds (see
# `TenantStreams::Reconciliation`). Once it has run for every tenant, the
# table is what a replay of the stream would write, so a projection that
# writes that table and has never been stamped can be stamped current
# without a reset. That is adoption: the table a release wrote directly
# becomes the projection's, and the deploy needs no rebuild.
#
# `events:reconcile` runs the list at predeploy steps 2b and 6.
module Projections::Reconcilers
  LIST = {
    "account_grants" => { reconciler: "AccountGrants::Reconciliation", adopts: %w[account_grants/account_flags] },
    "account_roles" => { reconciler: "AccountGrants::RoleReconciliation", adopts: %w[account_grants/account_flags] },
    "account_links" => { reconciler: "AccountGrants::LinkReconciliation", adopts: %w[account_grants/account_flags] },
    "tenant_planning_inputs" => { reconciler: "TenantPlanningInputs::Reconciliation", adopts: %w[tenant_planning_inputs/tables] }
  }.freeze

  # @return [Array<String>] the reconciler names
  def self.names
    LIST.keys
  end

  # @param name [String] a listed reconciler
  # @return [Class] its reconciler: `new(tenant).call` returns a `TenantStreams::Reconciliation::Report`
  def self.fetch(name)
    LIST.fetch(name).fetch(:reconciler).constantize
  end

  # Stamps each adopted projection that has no stamp yet. Call it only once
  # every reconciler has run for every tenant without failing.
  #
  # @return [Array<String>] the projection names stamped
  def self.adopt
    LIST.values.flat_map { it[:adopts] }.uniq.filter_map do |name|
      klass = Projections::Registry.fetch(name)
      ProjectionVersion.with_operation_lock(name) do
        next if ProjectionVersion.exists?(name:)

        ProjectionVersion.stamp!(klass)
        name
      end
    end
  end
end
