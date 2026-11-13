# frozen_string_literal: true

# Sets how long the tenant keeps the identifiers of people who have left,
# counted from each one's leaving date. Seven years until a tenant sets
# another period; `never` keeps them for ever.
#
# Approval is :in_app, as for the tenant's other settings: shortening the
# period makes leavers due to be forgotten, which can't be undone.
class Operations::Tenants::UpdateRetentionPeriod < Operations::Base
  description "Set how many years after a person leaves the active tenant forgets their identifiers " \
              "(default 7), or never forget them."
  category :write
  approval :in_app

  parameter :retention_years, Integer
  parameter :never, :boolean
  forbids_when :retention_years, if: :never, equals: true,
                                 message: "retention_years can't be given with never"

  def policy_check
    authorize ActsAsTenant.current_tenant, :update_retention_period?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id and the period as it now reads, nil for never
  def perform
    years = params[:never] ? nil : params[:retention_years]
    raise ParameterError, "give retention_years, or never: true" if years.nil? && !params[:never]

    tenant = ActsAsTenant.current_tenant
    config = tenant.org_graph_config.dup
    config.retention_years = years
    raise ParameterError, config.errors.full_messages.to_sentence unless config.valid?

    tenant.update!(org_graph_config: config)
    { tenant_id: tenant.id, retention_years: tenant.org_graph_config.retention_years }
  end
end
