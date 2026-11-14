# frozen_string_literal: true

# Sets how long the tenant keeps the identifiers of people who have left,
# counted from each one's leaving date. Seven years until a tenant sets
# another period; `never` keeps them for ever.
#
# Approval is :in_app, as for the tenant's other settings. Shortening the
# period only changes who is due; forgetting them is a separate,
# destructive step. So a period that makes more people due turns scheduled
# forgetting off, and turning it back on confirms a fresh count.
class Operations::Tenants::UpdateRetentionPeriod < Operations::Base
  description "Set how many years after a person leaves the active tenant forgets their identifiers " \
              "(default 7), or never forget them."
  category :write
  approval :in_app

  parameter :retention_years, Integer
  parameter :never, :boolean
  forbids_when :retention_years, if: :never, equals: true,
                                 message: "retention_years can't be given with never"

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :update_retention_period?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id, the period as it now reads (nil for never), and
  #   whether the change turned scheduled forgetting off
  def perform
    years = params[:never] ? nil : params[:retention_years]
    raise ParameterError, "give retention_years, or never: true" if years.nil? && !params[:never]

    tenant = ActsAsTenant.current_tenant
    stopped = false
    tenant.with_lock do
      config = tenant.org_graph_config.dup
      stopped = config.scheduled_forgetting && sooner?(years, config.retention_years)
      config.retention_years = years
      raise ParameterError, config.errors.full_messages.to_sentence unless config.valid?

      stop_schedule(config) if stopped
      tenant.update!(org_graph_config: config)
    end
    { tenant_id: tenant.id, retention_years: tenant.org_graph_config.retention_years, scheduled_forgetting_stopped: stopped }
  end

  private

  def sooner?(years, was) = !years.nil? && (was.nil? || years < was)

  def stop_schedule(config)
    config.scheduled_forgetting = false
    config.scheduled_forgetting_enabled_at = nil
    config.scheduled_forgetting_enabled_by_id = nil
  end
end
