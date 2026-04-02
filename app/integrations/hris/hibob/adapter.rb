# frozen_string_literal: true

# HiBob HRIS adapter. Syncs employee data from HiBob into Person records.
#
# Instantiated per-tenant with that tenant's credentials. Performs a four-pass
# sync: upsert employees, resolve managers, deactivate removed, auto-link users.
#
# @example
#   adapter = Hris::Hibob::Adapter.new(tenant)
#   result = adapter.sync_people
#   # => { created: 5, updated: 12, deactivated: 1, errors: [] }
#
class Hris::Hibob::Adapter < Hris::BaseAdapter
  # @return [String]
  def provider_name
    "hibob"
  end

  # Performs a full sync of employee data.
  #
  # Four-pass approach:
  # 1. Fetch all employees, upsert Person records (without manager_id)
  # 2. Resolve manager_id via external_id → Person lookup
  # 3. Deactivate HRIS-sourced people no longer in the API response
  # 4. Auto-link TenantUsers to Person records by email
  #
  # @return [Hash] summary with :created, :updated, :deactivated, :errors
  def sync_people
    employees = fetch_employees
    result = { created: 0, updated: 0, deactivated: 0, errors: [] }

    ActsAsTenant.with_tenant(tenant) do
      external_id_map = {}
      manager_links = {}

      # Pass 1: Upsert all employees
      employees.each do |raw_employee|
        mapper = Hris::Hibob::ResponseMapper.new(
          raw_employee,
          field_mappings: config.field_mappings
        )
        attrs = mapper.call
        manager_ext_id = mapper.manager_external_id

        person = upsert_person(attrs, result)
        if person
          external_id_map[attrs[:external_id]] = person
          manager_links[person] = manager_ext_id if manager_ext_id.present?
        end
      rescue => e
        result[:errors] << {
          external_id: raw_employee["id"],
          email: raw_employee["email"],
          error: e.message
        }
      end

      # Pass 2: Resolve manager relationships
      manager_links.each do |person, manager_ext_id|
        manager = external_id_map[manager_ext_id] ||
                  Person.find_by(external_id: manager_ext_id)
        person.update!(manager: manager) if manager && person.manager_id != manager.id
      end

      # Pass 3: Deactivate people no longer in HRIS
      deactivate_removed(employees, result)

      # Pass 4: Auto-link TenantUsers to Person records by email
      auto_link_tenant_users

      # Update last_synced_at
      config.last_synced_at = Time.current
      tenant.save!
    end

    result
  end

  # Fetches all employees from HiBob, handling pagination.
  #
  # @return [Array<Hash>] raw employee hashes
  def fetch_employees
    client.search_people(show_inactive: true)
  end

  private

  # @return [Hris::Hibob::Client]
  def client
    @client ||= begin
      creds = tenant.hris_credentials
      Hris::Hibob::Client.new(
        service_user_id: creds["service_user_id"],
        api_token: creds["api_token"]
      )
    end
  end

  # Upserts a single Person from mapped attributes.
  #
  # Matches by external_id first, then falls back to email. This handles
  # people who were manually created before HRIS sync was configured.
  #
  # @param attrs [Hash] Person-compatible attributes
  # @param result [Hash] running tally of sync results
  # @return [Person, nil] the created or updated person, nil on validation failure
  def upsert_person(attrs, result)
    person = Person.find_by(external_id: attrs[:external_id]) ||
             Person.find_by(email: attrs[:email]) ||
             Person.new
    is_new = person.new_record?

    person.assign_attributes(attrs.except(:hris_raw_data))
    person.hris_raw_data = attrs[:hris_raw_data]
    person.hris_source = "hibob"

    if person.changed? || is_new
      if person.save
        is_new ? result[:created] += 1 : result[:updated] += 1
      else
        result[:errors] << {
          external_id: attrs[:external_id],
          email: attrs[:email],
          error: person.errors.full_messages.join(", ")
        }
        return nil
      end
    end

    person
  end

  # Marks HRIS-sourced people as inactive if they no longer appear in the response.
  #
  # @param employees [Array<Hash>] current HiBob employees
  # @param result [Hash] running tally
  def deactivate_removed(employees, result)
    current_external_ids = employees.map { |e| e["id"] }.compact
    stale_people = Person.where(hris_source: "hibob", status: "active")
                         .where.not(external_id: current_external_ids)

    stale_people.find_each do |person|
      person.update!(status: "inactive")
      result[:deactivated] += 1
    end
  end

  # Links TenantUser records to Person records by matching email.
  #
  # Runs after upsert so newly created Person records are available for matching.
  def auto_link_tenant_users
    TenantUser.where(person_id: nil).includes(:user).find_each do |tu|
      person = Person.find_by(email: tu.user.email)
      tu.update!(person: person) if person
    end
  end
end
