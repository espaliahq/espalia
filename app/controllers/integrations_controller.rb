# frozen_string_literal: true

# Read-only management screens for tenant integrations.
#
# Currently surfaces the HRIS integration: provider/credential status,
# role mappings, and the resulting per-person assignments. Tenant admins
# can also trigger an on-demand re-sync.
#
# Designed to be extended with additional integration types (Slack,
# notifications, SSO) by adding new branches in {#show}.
#
class IntegrationsController < ApplicationController
  KNOWN_INTEGRATIONS = %w[hris].freeze

  # GET /integrations
  def index
    authorize :integrations, :index?

    render Views::Integrations::IndexView.new(
      hris_config: current_tenant.hris_config,
      hris_credentials_present: current_tenant.hris_credentials.present?,
      user: current_user,
      current_tenant: current_tenant,
      tenants: tenants_for_user
    )
  end

  # GET /integrations/:id
  def show
    authorize :integrations, :show?

    case params.expect(:id)
    when "hris"
      render_hris
    else
      redirect_to integrations_path, alert: "Unknown integration."
    end
  end

  # POST /integrations/:id/sync
  def sync
    authorize :integrations, :sync?

    case params.expect(:id)
    when "hris"
      enqueue_hris_sync
    else
      redirect_to integrations_path, alert: "Unknown integration."
    end
  end

  private

  def render_hris
    people = Person.hris_managed.includes(:manager).order(status: :asc, name: :asc).to_a
    rows = build_hris_rows(people)

    render Views::Integrations::HrisView.new(
      hris_config: current_tenant.hris_config,
      hris_credentials_present: current_tenant.hris_credentials.present?,
      person_rows: rows,
      role_mapping_rows: build_role_mapping_rows,
      user: current_user,
      current_tenant: current_tenant,
      tenants: tenants_for_user
    )
  end

  def enqueue_hris_sync
    if current_tenant.hris_config.configured?(current_tenant)
      HrisSyncJob.perform_later(current_tenant)
      redirect_to integration_path("hris"), notice: "HRIS sync queued. Refresh shortly to see updated results."
    else
      redirect_to integration_path("hris"),
                  alert: "HRIS integration is not fully configured — set provider, credentials, and enable sync."
    end
  end

  # Builds the per-person row data for the HRIS people table without N+1 queries.
  #
  # Pre-loads existing assignments, framework roles by code, and joins each
  # person to its resolved mapping/role/level using the same predicates as
  # {Hris::Hibob::Adapter#dispatch_framework_assignment}.
  #
  # @param people [Array<Person>]
  # @return [Array<Integrations::HrisPersonRow>]
  def build_hris_rows(people)
    return [] if people.empty?

    title_to_mapping = build_title_to_mapping
    roles_by_code = framework_roles_by_code
    levels_by_role_and_ordinal = framework_levels_by_role_and_ordinal
    assignments_by_person_id = preload_assignments(people, current_tenant.hris_config.role_mappings.any?)

    people.map do |person|
      mapping = resolve_mapping(person, title_to_mapping)
      role = mapping ? roles_by_code[mapping.framework_role_code] : nil
      level = role ? lookup_level(role, mapping, person, levels_by_role_and_ordinal) : nil

      Integrations::HrisPersonRow.new(
        person: person,
        mapping: mapping,
        role: role,
        level: level,
        assignment: assignments_by_person_id[person.id]
      )
    end
  end

  # @return [Hash{String => HrisRoleMapping}] normalized title → mapping lookup
  def build_title_to_mapping
    lookup = {}
    current_tenant.hris_config.role_mappings.each do |mapping|
      mapping.normalized_hris_titles.each { |title| lookup[title] = mapping }
    end
    lookup
  end

  # @return [Hash{String => FrameworkState::Role}]
  def framework_roles_by_code
    FrameworkState::Role.all.index_by(&:code)
  end

  # @return [Hash{[String, Integer] => FrameworkState::Level}] keyed by [role_id, ordinal]
  def framework_levels_by_role_and_ordinal
    FrameworkState::Level.all.index_by { |level| [level.role_id, level.ordinal] }
  end

  # @param people [Array<Person>]
  # @param has_mappings [Boolean]
  # @return [Hash{String => PersonFrameworkAssignment}]
  def preload_assignments(people, has_mappings)
    return {} unless has_mappings

    PersonFrameworkAssignment
      .where(person_id: people.map(&:id))
      .includes(:role, :level)
      .index_by(&:person_id)
  end

  def resolve_mapping(person, title_to_mapping)
    return nil if person.job_title.blank?

    title_to_mapping[person.job_title.to_s.downcase.strip]
  end

  def lookup_level(role, mapping, person, levels_by_role_and_ordinal)
    ordinal = mapping.level_ordinal || person.hris_level_ordinal
    return nil if ordinal.nil?

    levels_by_role_and_ordinal[[role.role_id, ordinal]]
  end

  # Each role mapping resolves once for the table on the HRIS show page —
  # the badge needs to know whether the framework actually contains the
  # configured role code.
  #
  # @return [Array<Hash>] one entry per role mapping with status metadata
  def build_role_mapping_rows
    roles_by_code = framework_roles_by_code

    current_tenant.hris_config.role_mappings.map do |mapping|
      role = roles_by_code[mapping.framework_role_code]
      {
        mapping: mapping,
        role: role,
        status_label: role.nil? ? "Missing role" : "OK",
        status_variant: role.nil? ? :warning : :success
      }
    end
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
