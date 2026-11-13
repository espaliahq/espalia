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

  # A deliberate brake: when more of the employed people vanish from one
  # response than both of these, the sync marks nobody as left. A partial
  # response, such as a service user who lost sight of a department, looks
  # exactly like a mass leaving, and a leaving stays in history. The next
  # sync decides afresh.
  ABSENCE_BRAKE = { share: 0.10, people: 5 }.freeze

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

  # The catalogue id a stored field reference stands for, so a value saved in
  # an older form still matches its field.
  #
  # @param field_id [String, nil]
  # @return [String, nil]
  def catalogue_id(field_id)
    field_id.presence
  end

  # Fetches the field catalogue from the HRIS API, uncached.
  #
  # @return [Array<Hris::Field>]
  def fetch_field_catalogue
    raise NotImplementedError, "#{self.class}#fetch_field_catalogue must be implemented"
  end

  # What each current person's record holds for one field, read live and
  # stored nowhere.
  #
  # @param field_id [String] the field's catalogue id
  # @param kind [Symbol] :list or :text
  # @return [Hash{String => Hris::FieldValue}] keyed by the person's external id
  def read_field(field_id, kind:)
    raise NotImplementedError, "#{self.class}#read_field must be implemented"
  end

  # Returns the provider name (e.g., "hibob", "bamboohr").
  #
  # @return [String]
  def provider_name
    raise NotImplementedError, "#{self.class}#provider_name must be implemented"
  end

  private

  # The provider's people a response no longer holds, or none when the
  # response is empty or trips {ABSENCE_BRAKE}. A refusal is reported in
  # the result's errors, with counts only.
  #
  # @param current_external_ids [Array<String>] the ids the response holds
  # @param result [Hash] running tally of sync results
  # @return [ActiveRecord::Relation<Person>]
  def absent_people(current_external_ids, result)
    if current_external_ids.empty?
      result[:errors] << { error: "#{provider_name} returned nobody, so no one was marked as left" }
      return Person.none
    end

    held = Person.where(hris_source: provider_name).where.not(external_id: nil)
    absent = held.where.not(external_id: current_external_ids).pluck(:id, :status)
    employed = held.where(status: "active").count
    vanished = absent.count { |_, status| status == "active" }
    return Person.where(id: absent.map(&:first)) unless vanished > ABSENCE_BRAKE[:people] && vanished > employed * ABSENCE_BRAKE[:share]

    message = "#{vanished} of #{employed} employed people are missing from #{provider_name}, more than " \
      "#{(ABSENCE_BRAKE[:share] * 100).round}% and #{ABSENCE_BRAKE[:people]} people, so no one was marked as left"
    Rails.logger.warn("[Hris] Absence brake for tenant #{tenant.id}: #{message}")
    result[:errors] << { error: message }
    Person.none
  end

  # Keyed on the service user too, so reconnecting to another HRIS account
  # never serves the old account's fields.
  def field_catalogue_cache_key
    account = Digest::SHA256.hexdigest(tenant.hris_secrets.service_user_id.to_s).first(16)
    [ "hris", "field_catalogue", tenant.id, provider_name, account, Hris::Field::SHAPE ]
  end

  attr_reader :tenant, :config, :correlation_id
end
