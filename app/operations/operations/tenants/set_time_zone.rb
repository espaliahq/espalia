# frozen_string_literal: true

# Sets the time zone the tenant works in, which decides its "today" ([#469](https://github.com/espaliahq/espalia/issues/469)).
# The change moves "today" from this moment on and rewrites nothing: dates
# already stored keep their day, and timestamps stay UTC.
class Operations::Tenants::SetTimeZone < Operations::Base
  description "Set the active tenant's time zone, any IANA name such as Australia/Sydney or America/Toronto. " \
              "It decides the tenant's today in team planning: the date a new plan starts from or is updated " \
              "to, and the last day drift and status read. It moves today from now on and rewrites no stored " \
              "date. Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :time_zone, String, required: true, allow_blank: false

  def policy_check
    authorize ActsAsTenant.current_tenant, :update_time_zone?, policy_class: TenantPolicy
  end

  # @return [Hash] `{ time_zone, today }`, today being the tenant's date in the new zone
  # @raise [Operations::Base::ParameterError] for a zone TZInfo doesn't know, or any other reason the tenant won't save
  def perform
    tenant = ActsAsTenant.current_tenant
    tenant.update!(time_zone: params[:time_zone])
    { time_zone: tenant.time_zone, today: tenant.today.iso8601 }
  rescue ActiveRecord::RecordInvalid => e
    tenant.restore_attributes([ :time_zone ])
    raise ParameterError, e.record.errors.full_messages.to_sentence
  end
end
