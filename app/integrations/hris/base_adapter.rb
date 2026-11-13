# frozen_string_literal: true

# Abstract interface for HRIS integration adapters.
#
# Each HRIS provider (HiBob, BambooHR, etc.) implements this interface.
# Adapters are plain Ruby classes instantiated with a tenant — no global singletons.
#
# @abstract Subclasses must implement {#sync_people}, {#fetch_employees},
#   {#fetch_field_catalogue}, and {#provider_name}.
#
# @example
#   adapter = Integrations::Hris::Hibob::Adapter.new(tenant)
#   result = adapter.sync_people
#   # => { created: 5, updated: 12, deactivated: 1, errors: [] }
#
class Hris::BaseAdapter
  FIELD_CATALOGUE_TTL = 1.hour

  # The adapter for the tenant's configured provider.
  #
  # @param tenant [Tenant]
  # @param correlation_id [String, nil]
  # @return [Hris::BaseAdapter]
  # @raise [ArgumentError] when the tenant has no provider Espalia knows
  def self.for(tenant, correlation_id: nil)
    case tenant.hris_config.provider
    when "hibob" then Hris::Hibob::Adapter.new(tenant, correlation_id:)
    else raise ArgumentError, "Unknown HRIS provider: #{tenant.hris_config.provider.inspect}"
    end
  end

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

  # The fields an admin can choose from, cached per tenant. An HRIS error
  # raises, and nothing is cached, so a failure never reads as "no fields".
  #
  # @return [Array<Hris::Field>]
  def field_catalogue
    cached = Rails.cache.fetch(field_catalogue_cache_key, expires_in: FIELD_CATALOGUE_TTL) do
      fetch_field_catalogue.map(&:to_h)
    end
    cached.map { Hris::Field.from_h(it) }
  end

  # Fetches the field catalogue from the HRIS API, uncached.
  #
  # @return [Array<Hris::Field>]
  def fetch_field_catalogue
    raise NotImplementedError, "#{self.class}#fetch_field_catalogue must be implemented"
  end

  # Returns the provider name (e.g., "hibob", "bamboohr").
  #
  # @return [String]
  def provider_name
    raise NotImplementedError, "#{self.class}#provider_name must be implemented"
  end

  private

  # Keyed on the service user too, so reconnecting to another HRIS account
  # never serves the old account's fields.
  def field_catalogue_cache_key
    account = Digest::SHA256.hexdigest(tenant.hris_secrets.service_user_id.to_s).first(16)
    [ "hris", "field_catalogue", tenant.id, provider_name, account, Hris::Field::SHAPE ]
  end

  attr_reader :tenant, :config, :correlation_id
end
