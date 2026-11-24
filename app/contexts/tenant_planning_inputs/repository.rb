# frozen_string_literal: true

# Loads and saves a tenant's planning inputs, held in one stream per tenant:
# `TenantPlanningInputs`.
#
# @example
#   TenantPlanningInputs::Repository.new.with_aggregate { |inputs| inputs.remove(:budget_lines, ...) }
class TenantPlanningInputs::Repository < TenantStreams::Repository
  private

  def new_aggregate = TenantPlanningInputs::Aggregate.new

  def stream_name(tenant) = EventStreamNaming.tenant_planning_inputs_stream(tenant:)
end
