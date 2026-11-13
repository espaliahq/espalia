# frozen_string_literal: true

# HiBob HRIS adapter. Syncs employee data from HiBob into Person records.
#
# Instantiated per-tenant with that tenant's credentials. Each sync upserts
# employees, resolves managers, records Org Graph differences, deactivates removed + offboards
# inactive (withdraw from open cycles, unassign), auto-link users, and assign
# to framework roles/levels.
#
# @example
#   adapter = Hris::Hibob::Adapter.new(tenant)
#   result = adapter.sync_people
#   # => { created: 5, updated: 12, deactivated: 1, assigned: 4, ... }
#
class Hris::Hibob::Adapter < Hris::BaseAdapter
  # The withdrawal/unassignment reason recorded on offboarding events
  # (Pass 3b). Never "cycle_closed" — that vocabulary is reserved for cycle
  # conclusion.
  OFFBOARD_REASON = "left_company"

  # HiBob field types whose values come from a named list, each with an id.
  LIST_TYPES = %w[list multi-list hierarchy-list].freeze

  # The columns {OrgGraph::Projections::PeopleColumns} writes once a tenant is cut over.
  PROJECTED_ATTRS = %i[job_title status].freeze

  # @return [String]
  def provider_name
    "hibob"
  end

  # Performs a full sync of employee data.
  #
  # The passes, in order:
  # 1. Fetch all employees, upsert Person records (without manager_id)
  # 2. Resolve manager_id via external_id → Person lookup
  # 2b. Record new people in the Org Graph, then write an event per fact that differs
  # 3. Deactivate HRIS-sourced people no longer in the API response, then
  #    offboard every inactive person still participating (Pass 3b —
  #    withdraw from open cycles, remove framework assignments)
  # 4. Auto-link TenantUsers to Person records by email
  # 5. Assign (or reassign) active people to framework roles/levels via
  #    role_mappings (inactive people are skipped — Pass 3b owns them)
  #
  # Once the tenant is cut over to the Org Graph, passes 1 to 3 leave
  # `job_title`, `manager_id` and `status` alone: Pass 2b's events write them
  # through {OrgGraph::Projections::PeopleColumns}, and Pass 3 records a leaving.
  #
  # @return [Hash] summary with :created, :updated, :deactivated, :offboarded, :org_graph_events,
  #   :skipped_inactive, :assigned,
  #   :role_changed, :level_changed, :unchanged, :errors,
  #   :unmapped_titles, :missing_roles, :missing_levels, :missing_ordinals,
  #   :skipped_no_title, :split_units (mirrored units whose people sit under different parents)
  def sync_people
    @sync_correlation_id = correlation_id.presence || SecureRandom.uuid_v7
    employees = fetch_employees
    result = build_initial_result

    # The flag is read once, so a cut-over waits for this sync to finish.
    OrgGraph::PeopleCutover.hold_off(tenant) do
      ActsAsTenant.with_tenant(tenant) do
        external_id_map = {}
        managers = Hash.new { |found, ext_id| found[ext_id] = external_id_map[ext_id] || Person.find_by(external_id: ext_id) }
        manager_links = {}
        touched_person_ids = []
        org_graph_facts = {}
        mirror_readings = {}
        projected = tenant.org_graph_people_projected?

        # Pass 1: Upsert all employees
        employees.each do |raw_employee|
          mapper = Hris::Hibob::ResponseMapper.new(
            raw_employee,
            level_field_id: config.level_field_id,
            mapped_fields:
          )
          # Dev-only PII guard — pass-through outside development.
          attrs = Hris::DevNameWhimsifier.call(mapper.call)
          manager_ext_id = mapper.manager_external_id

          person = upsert_person(attrs, result, projected:)
          if person
            external_id_map[attrs[:external_id]] = person
            manager_links[person] = manager_ext_id if manager_ext_id.present?
            touched_person_ids << person.id
            org_graph_facts[person] = { title: attrs[:job_title], level: mapper.level_label, manager_external_id: manager_ext_id,
                                        status: attrs[:status] }.compact.merge(mapper.org_graph_facts)
            mirror_readings[person] = mapper unless attrs[:status] == "inactive"
          end
        rescue => e
          result[:errors] << {
            external_id: raw_employee["id"],
            email: raw_employee["email"],
            error: e.message
          }
        end

        # Pass 2: Resolve manager relationships, unless the Org Graph writes them (Pass 2b)
        manager_links.each do |person, manager_ext_id|
          manager = managers[manager_ext_id]
          person.update!(manager: manager) if manager && person.manager_id != manager.id
        end unless projected

        # Pass 2b: Record new people in the Org Graph, then write each fact that differs
        record_org_graph_differences(org_graph_facts, managers, result)

        # Pass 2d: Mirror the structure levels HiBob provides, from each person's field
        mirror_structure_levels(mirror_readings, result)

        absent = absent_people(employees.filter_map { it["id"] }, result)
        leaving = Person.where(id: absent.where(status: "active").pluck(:id))

        # Pass 2c: Leave, in the Org Graph, everyone the response no longer holds
        record_org_graph_absences(absent, result)

        # Pass 3: Deactivate people no longer in HRIS
        deactivate_removed(leaving, result)

        # Pass 3b: Offboard every inactive person still participating —
        # withdraw from open cycles, remove framework assignments
        offboard_inactive(result)

        # Pass 4: Auto-link TenantUsers to Person records by email
        auto_link_tenant_users

        # Pass 5: Assign (or reassign) to framework roles/levels
        assign_to_framework(result, touched_person_ids)

        stamp_last_synced
      end
    end

    result
  end

  # Asks HiBob for one field beside each person's id, so a preview never
  # pulls the rest of their record.
  #
  # @param field_id [String]
  # @param kind [Symbol] :list or :text
  # @param alongside [String, nil] see {Hris::BaseAdapter#read_field}
  # @return [Hash{String => Hris::FieldValue}]
  def read_field(field_id, kind:, alongside: nil)
    fields = [ "root.id", catalogue_id(field_id) ]
    fields << Hris::Hibob::ResponseMapper::FACT_PATHS.fetch(alongside).join(".") if alongside
    employees = client.search_people(fields: fields.uniq, show_inactive: false)
    employees.each_with_object({}) do |employee, values|
      next if employee["id"].blank?

      values[employee["id"].to_s] = Hris::Hibob::ResponseMapper.new(employee).field_value(field_id, kind:, alongside:)
    end
  end

  # Fetches all employees from HiBob, handling pagination.
  #
  # @return [Array<Hash>] raw employee hashes
  def fetch_employees
    client.search_people(show_inactive: true)
  end

  # A bare custom-column id, the form stored before the picker, as its path.
  #
  # @param field_id [String, nil]
  # @return [String, nil]
  def catalogue_id(field_id)
    Hris::Hibob::Client.field_path(field_id)
  end

  # Reads HiBob's field metadata and named lists into the catalogue.
  #
  # @return [Array<Hris::Field>]
  # @raise [Hris::Hibob::Errors::Error] when either call fails or answers
  #   with a body of the wrong shape
  def fetch_field_catalogue
    fields = client.get_fields
    unexpected!("fields response is not a list") unless fields.is_a?(Array) && fields.all?(Hash)

    lists = fields.any? { list_type?(it) } ? named_lists_by_id(client.get_named_lists) : {}
    fields.filter_map { |field| catalogue_field(field, lists) }
  end

  private

  # @param field [Hash] one entry of GET /company/people/fields
  # @param lists [Hash{String => Array<Hris::Field::Value>}]
  # @return [Hris::Field, nil] nil for an entry with no path
  def catalogue_field(field, lists)
    id = field["jsonPath"].presence || field["id"].presence
    return if id.nil?

    name = field["name"].presence || id
    return Hris::Field.new(id:, name:, kind: :text) unless list_type?(field)

    type_data = field["typeData"]
    list_id = type_data["listId"].to_s if type_data.is_a?(Hash)
    Hris::Field.new(id:, name:, kind: :list, values: lists.fetch(list_id, []))
  end

  def list_type?(field) = LIST_TYPES.include?(field["type"])

  # HiBob documents the named lists as an array of `{ name, items }`. An
  # object keyed by list name is read too, as no live response has yet
  # confirmed which shape a tenant's account answers with. Either way a
  # field's `typeData.listId` is the list's key.
  #
  # @param response [Array<Hash>, Hash]
  # @return [Hash{String => Array<Hris::Field::Value>}]
  def named_lists_by_id(response)
    lists = case response
    when Array then response
    when Hash then response.map { |key, list| list.is_a?(Hash) ? list.merge("name" => key) : list }
    end
    unexpected!("named lists response is not a list") unless lists&.all?(Hash)

    lists.to_h { |list| [ list["name"].to_s, list_values(list_entries(list)) ] }
  end

  # HiBob documents a list's entries under `items`; its per-list example
  # shows `values`. A list with neither array is a body of the wrong shape,
  # such as an error, and must not read as a list with no values.
  #
  # @param list [Hash]
  # @return [Array<Hash>]
  def list_entries(list)
    entries = list.key?("items") ? list["items"] : list["values"]
    unexpected!("named list #{list["name"].inspect} has no items") unless entries.is_a?(Array)

    entries
  end

  # Flattens a hierarchy list, so a value at any depth can be chosen. An
  # archived value takes its children with it, and a value with no id is
  # left out, since nothing could refer to it.
  #
  # @param items [Array<Hash>, nil]
  # @return [Array<Hris::Field::Value>]
  def list_values(items)
    unexpected!("named list items are not a list") unless items.nil? || items.is_a?(Array)

    items.to_a.flat_map do |item|
      unexpected!("named list item is not an object") unless item.is_a?(Hash)
      next [] if item["archived"] || item["id"].blank?

      [ Hris::Field::Value.new(id: item["id"].to_s, name: item["name"].presence || item["value"].to_s),
        *list_values(item["children"]) ]
    end
  end

  # @param detail [String]
  # @raise [Hris::Hibob::Errors::UnexpectedResponseError]
  def unexpected!(detail)
    raise Hris::Hibob::Errors::UnexpectedResponseError, "HiBob #{detail}"
  end

  # `config` was read when the sync started; saving it would write back the
  # role mappings as they stood then, reverting any an admin changed while
  # the sync ran. Stamp a freshly locked copy instead.
  def stamp_last_synced
    tenant.with_lock do
      tenant.hris_config.last_synced_at = Time.current
      tenant.save!
    end
  end

  # @return [Hris::Hibob::Client]
  def client
    @client ||= begin
      creds = tenant.hris_secrets
      Hris::Hibob::Client.new(
        service_user_id: creds.service_user_id,
        api_token: creds.api_token,
        level_field_id: config.level_field_id,
        mapped_fields:,
        structure_fields: mirrored_levels.map(&:provider_field)
      )
    end
  end

  # The levels whose units this sync mirrors, top first.
  #
  # @return [Array<OrgTaxonomyLevel>]
  def mirrored_levels
    @mirrored_levels ||= ActsAsTenant.with_tenant(tenant) { Hris::LevelMirror.levels(provider_name) }
  end

  # The fields the tenant's Org Graph mapping names for HiBob.
  #
  # @return [Hash{String => String}]
  def mapped_fields
    @mapped_fields ||= ActsAsTenant.with_tenant(tenant) { OrgFactProvider.fields_for(provider_name) }
  end

  # @return [Hash] result hash seeded with zero counters and empty sets
  def build_initial_result
    {
      created: 0,
      updated: 0,
      deactivated: 0,
      offboarded: 0,
      org_graph_events: 0,
      skipped_inactive: 0,
      assigned: 0,
      role_changed: 0,
      level_changed: 0,
      unchanged: 0,
      skipped_no_title: 0,
      errors: [],
      split_units: [],
      unmapped_titles: Set.new,
      missing_roles: Set.new,
      missing_levels: Set.new,
      missing_ordinals: Set.new
    }
  end

  # Upserts a single Person from mapped attributes.
  #
  # Matches by external_id first, then falls back to email. The email match
  # claims only a person with no external id: one created by hand before the
  # sync was set up. A person who already holds another external id is a
  # different identity (a rehire under a new id, say), so the row is
  # skipped and reported rather than merged into their history.
  #
  # For a tenant cut over to the Org Graph, a new person's row starts with
  # HiBob's title and status, so a leaver is never briefly active; from then
  # on their stream writes both.
  #
  # @param attrs [Hash] Person-compatible attributes
  # @param result [Hash] running tally of sync results
  # @param projected [Boolean] whether the tenant is cut over to the Org Graph
  # @return [Person, nil] the created or updated person, nil when skipped or invalid
  def upsert_person(attrs, result, projected: false)
    person = Person.find_by(external_id: attrs[:external_id])
    unless person
      person = Person.find_by(email: attrs[:email])
      if person&.external_id.present?
        result[:errors] << {
          external_id: attrs[:external_id],
          email: attrs[:email],
          error: "Email belongs to a person with another HRIS id (#{person.external_id}); not merged"
        }
        return nil
      end
    end
    person ||= Person.new
    is_new = person.new_record?

    person.assign_attributes(attrs.except(:hris_raw_data, *(PROJECTED_ATTRS if projected && !is_new)))
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

  # Pass 2b: records a person the Org Graph has not seen, with the facts as
  # they stand (an inactive person as having left), and otherwise compares
  # each row's operational facts with their stream and writes an event for
  # each that differs. A fact the row
  # does not supply is left out, never cleared. A manager is read from the
  # row itself, so a lost manager is recorded even though Pass 2 never
  # clears one; a manager the sync cannot find, or the person themself, is
  # left uncompared. A change in employment status is written too, a join
  # on the start date and a leaving on the termination date when HiBob holds
  # them; a leaver's other facts are not compared.
  #
  # @param rows [Hash{Person => Hash}] title, level, manager_external_id and
  #   HiBob's status and the mapper's {Hris::Hibob::ResponseMapper#org_graph_facts} per person
  # @param managers [Hash{String => Person, nil}] each manager external id, resolved once
  # @param result [Hash] running tally
  def record_org_graph_differences(rows, managers, result)
    with_hris_event_context do
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      today = Date.current

      rows.each do |person, row|
        facts = row.slice(:title, :level, :cost_centre, :site, :country, :fte, :employment_type)
        if row[:manager_external_id].nil?
          facts[:manager_id] = nil
        elsif (manager = managers[row[:manager_external_id]]) && manager != person
          facts[:manager_id] = manager.id
        end

        result[:org_graph_events] += handler.sync_person(person.id, provider: provider_name, effective_on: today,
          employment_status: org_graph_status(row[:status], row[:started_on], today),
          started_on: row[:started_on], left_on: row[:terminated_on], **facts)
      rescue => e
        result[:errors] << { person_id: person.id, error: e.message }
      end
    end
  end

  # A failed catalogue read mirrors nothing, so no unit retires for want of
  # its list.
  #
  # @param readings [Hash{Person => Hris::Hibob::ResponseMapper}] current people
  # @param result [Hash] running tally
  def mirror_structure_levels(readings, result)
    return if mirrored_levels.empty?

    catalogue = begin
      fetch_field_catalogue
    rescue Hris::Hibob::Errors::Error => e
      result[:errors] << { error: "HiBob's field lists could not be read, so no structure level was mirrored: #{e.message}" }
      return
    end

    with_hris_event_context do
      Hris::LevelMirror.new(provider: provider_name, catalogue:, readings:, result:, levels: mirrored_levels).call
    end
  end

  # A person HiBob stops returning has left, dated by the sync that first
  # misses them.
  #
  # @param absent [ActiveRecord::Relation<Person>] from {#absent_people}
  # @param result [Hash] running tally
  def record_org_graph_absences(absent, result)
    with_hris_event_context do
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      today = Date.current

      absent.find_each do |person|
        result[:org_graph_events] += handler.record_absence(person.id, provider: provider_name, effective_on: today)
      rescue => e
        result[:errors] << { person_id: person.id, error: e.message }
      end
    end
  end

  # HiBob marks a hire active before they start, so a start date still ahead
  # means pending. The status is HiBob's, never the row's: once the tenant is
  # cut over, the row holds only what the stream has already projected.
  #
  # @param status [String, nil] HiBob's status, "active" or "inactive"
  # @return [String] "left", "pending" or "employed"
  def org_graph_status(status, started_on, today)
    return "left" if status == "inactive"

    started_on.present? && Date.iso8601(started_on) > today ? "pending" : "employed"
  end

  # Marks HRIS-sourced people as inactive if they no longer appear in the response.
  #
  # @param leaving [ActiveRecord::Relation<Person>] the absent people who were active before Pass 2c
  # @param result [Hash] running tally
  def deactivate_removed(leaving, result)
    return deactivate_in_org_graph(leaving, result) if tenant.org_graph_people_projected?

    leaving.find_each do |person|
      person.update!(status: "inactive")
      result[:deactivated] += 1
    end
  end

  # Pass 3 for a tenant cut over to the Org Graph: Pass 2c has already left
  # everyone recorded, so this counts them and records anyone the Org Graph
  # never saw as having left, with the facts on their row.
  #
  # @param stale_people [ActiveRecord::Relation<Person>]
  # @param result [Hash] running tally
  def deactivate_in_org_graph(stale_people, result)
    with_hris_event_context do
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      recorded = OrgGraph::Projections::PeopleColumns.recorded_person_ids(tenant).to_set
      stale_people.find_each do |person|
        result[:org_graph_events] += record_as_left(handler, person) unless recorded.include?(person.id)
        result[:deactivated] += 1 if person.reload.status == "inactive"
      rescue => e
        result[:errors] << { person_id: person.id, error: e.message }
      end
    end
  end

  ESPALIA_CHANGES = { title: :change_title, manager_id: :change_manager }.freeze

  # Records a person with no stream as having left, keeping the title and
  # manager on their row. Each fact is written by whoever holds it, since
  # one command can't carry facts split between HiBob and Espalia. They
  # commit together, or a half-written leaver would never be revisited.
  def record_as_left(handler, person)
    today = Date.current
    ours, espalias = first_record_facts(person).partition do |key, _|
      OrgFactProvider.provider_for(OrgGraph::PersonAggregate::FACT_KINDS.fetch(key)) == provider_name
    end.map(&:to_h)
    Person.transaction(requires_new: true) do
      handler.sync_person(person.id, provider: provider_name, effective_on: today, employment_status: "left", **ours)
      espalias.compact.each do |key, value|
        handler.public_send(ESPALIA_CHANGES.fetch(key), person.id, value, provider: OrgGraph::StructureAggregate::ESPALIA, effective_on: today)
      end
    end
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id)).count
  end

  def first_record_facts(person)
    { title: person.job_title, manager_id: (person.manager_id unless person.manager_id == person.id) }
  end

  # Pass 3b: enforces the invariant "an inactive person holds no live
  # participation" — withdraws them from any OPEN cycle (a person-scoped
  # removal, never a conclusion) and removes their framework assignments so
  # they stop appearing in eligible-people lists and manager views.
  #
  # Deliberately state-driven rather than transition-driven: it sweeps every
  # inactive person with lingering participation, however they became
  # inactive (absent from the response — Pass 3; present with
  # `isActive: false` — Pass 1; or a manual admin edit), so each sync also
  # self-heals stragglers left by earlier code and the sweep is idempotent.
  #
  # Withdrawal must precede unassignment — the PersonDevelopment aggregate
  # refuses to unassign while the person is enrolled in a cycle.
  #
  # A returnee (seasonal / boomerang) reversing this is the normal new-hire
  # path: Pass 1 flips them back to active, Pass 5 re-assigns (their
  # assignment row is gone, so the `existing.nil?` branch fires), and
  # AutoEnrollNewAssignments enrolls them into any open cycle with a fresh
  # progress slate (plus prior-aligned-cycle rating seeds, if any).
  #
  # @param result [Hash] running tally
  def offboard_inactive(result)
    inactive_ids = Person.inactive.select(:id)

    open_enrollments = AssessmentCycleEnrollment.active
      .where(person_id: inactive_ids)
      .joins(:cycle).where(assessment_cycles: { status: "open" })
      .to_a.group_by(&:person_id)
    assignments = PersonFrameworkAssignment
      .where(person_id: inactive_ids)
      .to_a.group_by(&:person_id)
    return if open_enrollments.empty? && assignments.empty?

    with_hris_event_context do
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new

      (open_enrollments.keys | assignments.keys).each do |person_id|
        Array(open_enrollments[person_id]).each do |enrollment|
          cycles_handler.unenroll(enrollment.cycle_id, person_id, OFFBOARD_REASON)
        end
        Array(assignments[person_id]).each do |assignment|
          pd_handler.unassign_from_framework(
            person_id, assignment.framework_id, reason: OFFBOARD_REASON
          )
        end
        result[:offboarded] += 1
      rescue => e
        result[:errors] << { person_id: person_id, error: e.message }
      end
    end
  end

  # Wraps event-dispatching sync passes (3b + 5) in the shared provenance
  # context: acting_via :hris + the sync's correlation_id on every event's
  # metadata, plus the tenant id the projections and replayer rely on.
  def with_hris_event_context(&block)
    AuditMetadata.with(acting_via: :hris, correlation_id: @sync_correlation_id || correlation_id.presence || SecureRandom.uuid_v7) do
      AuditMetadata.wrap_event_store do
        Rails.configuration.event_store.with_metadata(tenant_id: tenant.id, &block)
      end
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
  # person.hris_level_ordinal (Mode 2). The resolution itself is
  # {Integrations::HrisTitleResolution} — shared with the integrations page
  # and the MCP tools, so they can't describe a different sync.
  #
  # Dispatches one of three commands per person:
  # - `assign_to_framework` — no existing assignment
  # - `change_person_role` — role differs (level also changes, role-scoped)
  # - `change_person_level` — only level differs
  #
  # The entire loop runs inside `event_store.with_metadata(tenant_id:)` so
  # the CurrentAssessment projection can resolve tenant context, AND inside
  # `AuditMetadata.with(:hris, ...)` so every event is attributable to a sync
  # run (vs a web request or MCP client) and correlated by a single run id in
  # the activity log. `actor_id` is intentionally nil — an HRIS sync has no
  # human actor; the `correlation_id` (the enqueuing job's id, or a fresh
  # uuid when run inline) is the unit of attribution.
  #
  # @param result [Hash] running tally of sync results
  # @param touched_person_ids [Array<String>] Person ids touched in Pass 1
  def assign_to_framework(result, touched_person_ids)
    return if config.role_mappings.blank?
    return if touched_person_ids.empty?

    resolution = Integrations::HrisTitleResolution.new(tenant)
    framework = resolution.framework
    return if framework.nil?

    with_hris_event_context do
      command_handler = PersonDevelopment::CommandHandler.new

      resolution.rows(Person.where(id: touched_person_ids)).each do |row|
        # HiBob returns inactive employees too (show_inactive: true) —
        # they are offboarded by Pass 3b, never (re-)assigned here.
        if row.status == Integrations::HrisPersonRow::STATUS_INACTIVE
          result[:skipped_inactive] += 1
          next
        end

        dispatch_framework_assignment(row: row, framework: framework, command_handler: command_handler, result: result)
        record_reporting_manager(person: row.person, framework: framework, command_handler: command_handler)
      end
    end
  end

  # Dispatches the command a resolved row calls for, or tallies why it can't.
  #
  # @param row [Integrations::HrisPersonRow]
  # @param framework [FrameworkState::Framework]
  # @param command_handler [PersonDevelopment::CommandHandler]
  # @param result [Hash]
  def dispatch_framework_assignment(row:, framework:, command_handler:, result:)
    person = row.person

    case row.status
    when Integrations::HrisPersonRow::STATUS_NO_TITLE
      result[:skipped_no_title] += 1
    when Integrations::HrisPersonRow::STATUS_UNMAPPED
      result[:unmapped_titles] << person.job_title
    when Integrations::HrisPersonRow::STATUS_MISSING_ROLE
      result[:missing_roles] << row.mapping.framework_role_code
    when Integrations::HrisPersonRow::STATUS_MISSING_ORDINAL
      result[:missing_ordinals] << { title: person.job_title, code: row.mapping.framework_role_code }
    when Integrations::HrisPersonRow::STATUS_MISSING_LEVEL
      result[:missing_levels] << { code: row.mapping.framework_role_code, ordinal: row.resolved_ordinal }
    when Integrations::HrisPersonRow::STATUS_PENDING_SYNC
      command_handler.assign_to_framework(person.id, framework.framework_id, row.role.role_id, row.level.level_id)
      result[:assigned] += 1
    when Integrations::HrisPersonRow::STATUS_ASSIGNED
      result[:unchanged] += 1
    when Integrations::HrisPersonRow::STATUS_DRIFT
      if row.assignment.role_id != row.role.role_id
        command_handler.change_person_role(person.id, framework.framework_id, row.role.role_id, row.level.level_id)
        result[:role_changed] += 1
      else
        command_handler.change_person_level(person.id, framework.framework_id, row.level.level_id)
        result[:level_changed] += 1
      end
    end
  end

  # Records the reporting manager as a first-class fact on the stream so the
  # aggregate / policy can gate manager-rating authority. Runs for every touched
  # person that has a framework assignment — independent of whether Pass 5's
  # mapping succeeded — so a re-managed person whose title later becomes unmapped
  # still gets a fresh recording. Idempotent: a no-op when unchanged, when the
  # person has no manager, or when they have no assignment yet.
  #
  # @param person [Person]
  # @param framework [FrameworkState::Framework]
  # @param command_handler [PersonDevelopment::CommandHandler]
  def record_reporting_manager(person:, framework:, command_handler:)
    return unless PersonFrameworkAssignment.exists?(
      person_id: person.id, framework_id: framework.framework_id
    )

    command_handler.record_reporting_manager(
      person.id, framework.framework_id, person.manager_id, source: "hris"
    )
  end
end
