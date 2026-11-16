# frozen_string_literal: true

# Sets the time zone the tenant works in, which decides its "today" (#469).
# The change moves "today" from this moment on and rewrites nothing: dates
# already stored keep their day, and timestamps stay UTC.
class Operations::Tenants::SetTimeZone < Operations::Base
  description "Set the active tenant's time zone, an IANA name such as Australia/Sydney. It decides the " \
              "tenant's today: the default date of a plan, a change or an Org Graph fact. It moves today " \
              "from now on and rewrites no stored date. Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :time_zone, String, required: true, allow_blank: false

  def policy_check
    authorize ActsAsTenant.current_tenant, :update_time_zone?, policy_class: TenantPolicy
  end

  # @return [Hash] `{ time_zone, today }`, today being the tenant's date in the new zone
  def perform
    unless Tenant.time_zone_names.include?(params[:time_zone])
      raise ParameterError, "time_zone: #{params[:time_zone]} isn't a time zone we know; use an IANA name such as Australia/Sydney"
    end

    tenant = ActsAsTenant.current_tenant
    tenant.update!(time_zone: params[:time_zone])
    { time_zone: tenant.time_zone, today: tenant.today.iso8601 }
  end
end
