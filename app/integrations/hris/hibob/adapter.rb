# frozen_string_literal: true

# HiBob HRIS adapter. Syncs employee data from HiBob into Person records.
#
# Instantiated per-tenant with that tenant's credentials. Performs a five-pass
# sync: upsert employees, resolve managers, deactivate removed, auto-link users,
# and assign to framework roles/levels.
#
# @example
#   adapter = Hris::Hibob::Adapter.new(tenant)
#   result = adapter.sync_people
#   # => { created: 5, updated: 12, deactivated: 1, assigned: 4, ... }
#
class Hris::Hibob::Adapter < Hris::BaseAdapter
  # @return [String]
  def provider_name
    "hibob"
  end

  # Performs a full sync of employee data.
  #
  # Five-pass approach:
  # 1. Fetch all employees, upsert Person records (without manager_id)
  # 2. Resolve manager_id via external_id → Person lookup
  # 3. Deactivate HRIS-sourced people no longer in the API response
  # 4. Auto-link TenantUsers to Person records by email
  # 5. Assign (or reassign) people to framework roles/levels via role_mappings
  #
  # @return [Hash] summary with :created, :updated, :deactivated, :assigned,
  #   :role_changed, :level_changed, :unchanged, :errors,
  #   :unmapped_titles, :missing_roles, :missing_levels, :missing_ordinals,
  #   :skipped_no_title
  def sync_people
    employees = fetch_employees
    result = build_initial_result

    ActsAsTenant.with_tenant(tenant) do
      external_id_map = {}
      manager_links = {}
      touched_person_ids = []

      # Pass 1: Upsert all employees
      employees.each do |raw_employee|
        mapper = Hris::Hibob::ResponseMapper.new(
          raw_employee,
          field_mappings: config.field_mappings,
          level_field_id: config.level_field_id
        )
        attrs = mapper.call
        manager_ext_id = mapper.manager_external_id

        person = upsert_person(attrs, result)
        if person
          external_id_map[attrs[:external_id]] = person
          manager_links[person] = manager_ext_id if manager_ext_id.present?
          touched_person_ids << person.id
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

      # Pass 5: Assign (or reassign) to framework roles/levels
      assign_to_framework(result, touched_person_ids)

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
        api_token: creds["api_token"],
        level_field_id: config.level_field_id
      )
    end
  end

  # @return [Hash] result hash seeded with zero counters and empty sets
  def build_initial_result
    {
      created: 0,
      updated: 0,
      deactivated: 0,
      assigned: 0,
      role_changed: 0,
      level_changed: 0,
      unchanged: 0,
      skipped_no_title: 0,
      errors: [],
      unmapped_titles: Set.new,
      missing_roles: Set.new,
      missing_levels: Set.new,
      missing_ordinals: Set.new
    }
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

  # Assigns (or reassigns) touched Person records to framework roles/levels.
  #
  # Uses config.role_mappings to match job_title → framework role.
  # Level ordinal comes from the mapping (Mode 1) or falls back to
  # person.hris_level_ordinal (Mode 2).
  #
  # Dispatches one of three commands per person:
  # - `assign_to_framework` — no existing assignment
  # - `change_person_role` — role differs (level also changes, role-scoped)
  # - `change_person_level` — only level differs
  #
  # The entire loop runs inside `event_store.with_metadata(tenant_id:)` so
  # the CurrentAssessment projection can resolve tenant context.
  #
  # @param result [Hash] running tally of sync results
  # @param touched_person_ids [Array<String>] Person ids touched in Pass 1
  def assign_to_framework(result, touched_person_ids)
    return if config.role_mappings.blank?
    return if touched_person_ids.empty?

    framework = FrameworkState::Framework.first
    return if framework.nil?

    title_to_mapping = build_title_to_mapping
    roles_by_code = framework_roles_by_code

    Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
      command_handler = PersonDevelopment::CommandHandler.new

      Person.where(id: touched_person_ids).find_each do |person|
        dispatch_framework_assignment(
          person: person,
          framework: framework,
          title_to_mapping: title_to_mapping,
          roles_by_code: roles_by_code,
          command_handler: command_handler,
          result: result
        )
      end
    end
  end

  # Builds a normalized-title → HrisRoleMapping lookup for the tenant.
  #
  # @return [Hash{String => HrisRoleMapping}]
  def build_title_to_mapping
    lookup = {}
    config.role_mappings.each do |mapping|
      mapping.normalized_hris_titles.each do |title|
        lookup[title] = mapping
      end
    end
    lookup
  end

  # Preloads all framework roles keyed by code for fast lookup.
  #
  # @return [Hash{String => FrameworkState::Role}]
  def framework_roles_by_code
    FrameworkState::Role.all.index_by(&:code)
  end

  # Dispatches the appropriate framework assignment command for a single person.
  #
  # @param person [Person]
  # @param framework [FrameworkState::Framework]
  # @param title_to_mapping [Hash{String => HrisRoleMapping}]
  # @param roles_by_code [Hash{String => FrameworkState::Role}]
  # @param command_handler [PersonDevelopment::CommandHandler]
  # @param result [Hash]
  def dispatch_framework_assignment(person:, framework:, title_to_mapping:, roles_by_code:, command_handler:, result:)
    if person.job_title.blank?
      result[:skipped_no_title] += 1
      return
    end

    mapping = title_to_mapping[person.job_title.to_s.downcase.strip]
    if mapping.nil?
      result[:unmapped_titles] << person.job_title
      return
    end

    role = roles_by_code[mapping.framework_role_code]
    if role.nil?
      result[:missing_roles] << mapping.framework_role_code
      return
    end

    resolved_ordinal = mapping.level_ordinal || person.hris_level_ordinal
    if resolved_ordinal.nil?
      result[:missing_ordinals] << { title: person.job_title, code: mapping.framework_role_code }
      return
    end

    level = FrameworkState::Level.find_by(role_id: role.role_id, ordinal: resolved_ordinal)
    if level.nil?
      result[:missing_levels] << { code: mapping.framework_role_code, ordinal: resolved_ordinal }
      return
    end

    existing = PersonFrameworkAssignment.find_by(
      person_id: person.id,
      framework_id: framework.framework_id
    )

    if existing.nil?
      command_handler.assign_to_framework(person.id, framework.framework_id, role.role_id, level.level_id)
      result[:assigned] += 1
    elsif existing.role_id == role.role_id && existing.level_id == level.level_id
      result[:unchanged] += 1
    elsif existing.role_id != role.role_id
      command_handler.change_person_role(person.id, framework.framework_id, role.role_id, level.level_id)
      result[:role_changed] += 1
    else
      command_handler.change_person_level(person.id, framework.framework_id, level.level_id)
      result[:level_changed] += 1
    end
  end
end
