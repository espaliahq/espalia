# frozen_string_literal: true

# Abstract interface for HRIS integration adapters.
#
# Each HRIS provider (HiBob, BambooHR, etc.) implements this interface.
# Adapters are plain Ruby classes instantiated with a tenant — no global singletons.
#
# @abstract Subclasses must implement {#sync_people}, {#fetch_employees}, and {#provider_name}.
#
# @example
#   adapter = Integrations::Hris::Hibob::Adapter.new(tenant)
#   result = adapter.sync_people
#   # => { created: 5, updated: 12, deactivated: 1, errors: [] }
#
class Hris::BaseAdapter
  # @param tenant [Tenant] the tenant whose HRIS data to sync
  # @param correlation_id [String, nil] id correlating every event this
  #   sync run produces — typically the enqueuing job's id. Falls back to
  #   a fresh uuid per run when nil (see the adapter's audit wrap).
  def initialize(tenant, correlation_id: nil)
    @tenant = tenant
    @config = tenant.hris_config
    @correlation_id = correlation_id
  end

  # Performs a full sync of employee data into Person records.
  #
  # @return [Hash] summary with :created, :updated, :deactivated, :errors counts
  def sync_people
    raise NotImplementedError, "#{self.class}#sync_people must be implemented"
  end

  # Fetches all employees from the HRIS API.
  #
  # @return [Array<Hash>] raw employee data from the HRIS
  def fetch_employees
    raise NotImplementedError, "#{self.class}#fetch_employees must be implemented"
  end

  # Returns the provider name (e.g., "hibob", "bamboohr").
  #
  # @return [String]
  def provider_name
    raise NotImplementedError, "#{self.class}#provider_name must be implemented"
  end

  private

  attr_reader :tenant, :config, :correlation_id
end
