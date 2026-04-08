# frozen_string_literal: true

# HRIS integration management view.
#
# Three sections rendered as cards:
#  1. Configuration — provider, credential presence, sync enable flag,
#     custom level column id, last sync timestamp, and a "Sync now" button.
#  2. Role Mappings — every HrisRoleMapping with the resolved framework role.
#  3. Imported People — every HRIS-managed Person with their resolved
#     mapping/assignment status (computed via {Integrations::HrisPersonRow}).
#
class Views::Integrations::HrisView < Views::Base
  # @param hris_config [HrisConfig]
  # @param hris_credentials_present [Boolean]
  # @param person_rows [Array<Integrations::HrisPersonRow>]
  # @param role_mapping_rows [Array<Hash>] each entry: { mapping:, role:, status_label:, status_variant: }
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(hris_config:, hris_credentials_present:, person_rows:, role_mapping_rows:,
                 user: nil, current_tenant: nil, tenants: [])
    @hris_config = hris_config
    @hris_credentials_present = hris_credentials_present
    @person_rows = person_rows
    @role_mapping_rows = role_mapping_rows
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-6xl mx-auto px-4 py-8 space-y-10") do
        page_header
        configuration_section
        role_mappings_section
        people_section
      end
    end
  end

  private

  # ── Header ──

  def page_header
    div(class: "mb-6") do
      a(
        href: integrations_path,
        class: "text-sm text-gray-500 dark:text-gray-400 hover:text-gray-700 " \
               "dark:hover:text-gray-200 transition-colors"
      ) { plain "\u2190 Back to Integrations" }

      div(class: "mt-2 flex items-center gap-3") do
        h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "HRIS Integration" }
        render Components::Kit::Badge.new(provider_label, variant: :info)
      end
      p(class: "mt-1 text-sm text-gray-500 dark:text-gray-400") do
        plain "Sync employee data from your HRIS to keep people, roles, and levels up to date."
      end
    end
  end

  # ── Configuration ──

  def configuration_section
    div do
      render Components::Kit::SectionHeading.new(
        "Configuration",
        subtitle: "Read-only view of the HRIS configuration for this workspace"
      )

      render Components::Kit::Card.new do |card|
        card.body do
          render Components::Kit::DescriptionList.new(items: configuration_items, columns: 3)
          sync_form
        end
      end
    end
  end

  def configuration_items
    [
      { term: "Provider", detail: provider_label },
      { term: "Sync enabled", detail: yes_no(@hris_config.sync_enabled?) },
      { term: "Last synced", detail: last_synced_label },
      { term: "Credentials", detail: yes_no(@hris_credentials_present) },
      { term: "Level column id", detail: @hris_config.level_field_id.presence || "\u2014" },
      { term: "Webhook secret", detail: yes_no(@hris_config.webhook_secret.present?) }
    ]
  end

  def sync_form
    div(class: "mt-6 pt-6 border-t border-gray-200 dark:border-gray-700") do
      form(
        action: sync_integration_path("hris"),
        method: "post",
        class: "flex items-center gap-4"
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

        button(
          type: "submit",
          class: "inline-flex items-center rounded-sm bg-primary px-4 py-2 text-sm " \
                 "font-semibold text-white shadow-xs hover:bg-primary/90 " \
                 "focus:outline-hidden focus:ring-2 focus:ring-primary focus:ring-offset-2 " \
                 "transition-colors disabled:opacity-50 disabled:cursor-not-allowed",
          disabled: !sync_ready?
        ) { "Sync now" }

        unless sync_ready?
          p(class: "text-xs text-gray-500 dark:text-gray-400") do
            plain "Configure provider, credentials, and enable sync to trigger an on-demand sync."
          end
        end
      end
    end
  end

  # ── Role Mappings ──

  def role_mappings_section
    div do
      render Components::Kit::SectionHeading.new(
        "Role Mappings",
        subtitle: "How HRIS job titles are translated into framework roles and levels"
      )

      render Components::Kit::Card.new(variant: :flush) do |card|
        card.body do
          if @role_mapping_rows.empty?
            empty_state("No role mappings configured.")
          else
            role_mappings_table
          end
        end
      end
    end
  end

  def role_mappings_table
    div(class: "overflow-x-auto") do
      table(class: "min-w-full text-sm") do
        thead(class: "bg-gray-50 dark:bg-gray-800/50") do
          tr do
            th_cell("HRIS titles")
            th_cell("Framework role")
            th_cell("Level")
            th_cell("Status")
          end
        end
        tbody(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          @role_mapping_rows.each { |row| role_mapping_row(row) }
        end
      end
    end
  end

  def role_mapping_row(row)
    tr do
      td_cell { titles_list(row[:mapping].hris_titles) }
      td_cell { framework_role_cell(row) }
      td_cell { level_ordinal_cell(row[:mapping]) }
      td_cell { render Components::Kit::Badge.new(row[:status_label], variant: row[:status_variant]) }
    end
  end

  def titles_list(titles)
    div(class: "flex flex-wrap gap-1") do
      Array(titles).each do |title|
        span(
          class: "inline-flex items-center rounded-sm px-2 py-0.5 text-xs " \
                 "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300"
        ) { title }
      end
    end
  end

  def framework_role_cell(row)
    if row[:role]
      span(class: "font-mono text-gray-900 dark:text-white") { row[:mapping].framework_role_code }
      span(class: "ml-2 text-gray-500 dark:text-gray-400") { row[:role].name }
    else
      span(class: "font-mono text-gray-900 dark:text-white") { row[:mapping].framework_role_code }
    end
  end

  def level_ordinal_cell(mapping)
    if mapping.level_ordinal
      span(class: "font-mono") { "L#{mapping.level_ordinal}" }
    else
      span(class: "text-xs text-gray-500 dark:text-gray-400") { "from custom column" }
    end
  end

  # ── People ──

  def people_section
    div do
      render Components::Kit::SectionHeading.new(
        "Imported People",
        subtitle: "#{@person_rows.size} #{'person'.pluralize(@person_rows.size)} synced from HRIS"
      )

      render Components::Kit::Card.new(variant: :flush) do |card|
        card.body do
          if @person_rows.empty?
            empty_state("No people have been imported from the HRIS yet.")
          else
            people_table
          end
        end
      end
    end
  end

  def people_table
    div(class: "overflow-x-auto") do
      table(class: "min-w-full text-sm") do
        thead(class: "bg-gray-50 dark:bg-gray-800/50") do
          tr do
            th_cell("Person")
            th_cell("Department")
            th_cell("Job title")
            th_cell("Mapped role")
            th_cell("Assigned")
            th_cell("Manager")
            th_cell("Status")
          end
        end
        tbody(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          @person_rows.each { |row| person_row(row) }
        end
      end
    end
  end

  def person_row(row)
    tr do
      td_cell { person_identity(row.person) }
      td_cell { row.person.department.presence || "\u2014" }
      td_cell { row.person.job_title.presence || "\u2014" }
      td_cell { mapped_role_cell(row) }
      td_cell { span(class: "font-mono") { row.assigned_label } }
      td_cell { row.person.manager&.name || "\u2014" }
      td_cell { render Components::Kit::Badge.new(row.status_label, variant: row.status_variant) }
    end
  end

  def person_identity(person)
    div do
      div(class: "font-medium text-gray-900 dark:text-white") { person.name }
      div(class: "text-xs text-gray-500 dark:text-gray-400") { person.email }
    end
  end

  def mapped_role_cell(row)
    if row.mapping
      span(class: "font-mono") { row.mapped_role_code }
    else
      span(class: "text-gray-400") { "\u2014" }
    end
  end

  # ── Helpers ──

  def empty_state(text)
    div(class: "px-6 py-10 text-center text-sm text-gray-500 dark:text-gray-400") { text }
  end

  def th_cell(label)
    th(
      scope: "col",
      class: "px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide " \
             "text-gray-500 dark:text-gray-400"
    ) { label }
  end

  def td_cell(&block)
    td(class: "px-4 py-3 align-top text-gray-900 dark:text-gray-100", &block)
  end

  def yes_no(value)
    value ? "Yes" : "No"
  end

  def provider_label
    @hris_config.provider.presence&.humanize || "Not configured"
  end

  def last_synced_label
    @hris_config.last_synced_at&.to_fs(:long) || "Never"
  end

  def sync_ready?
    @hris_config.configured?(@current_tenant)
  end
end
