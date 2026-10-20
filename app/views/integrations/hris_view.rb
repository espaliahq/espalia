# frozen_string_literal: true

# HRIS integration management view.
#
# Four sections rendered as cards:
#  1. Configuration — provider, credential presence, sync enable flag,
#     custom level column id, last sync timestamp, and a "Sync now" button.
#  2. Unmapped titles — HRIS titles no mapping covers, each with a "Map…"
#     action (#436). The sync skips these people without a word, so this
#     card is the only place the gap shows.
#  3. Role Mappings — every HrisRoleMapping with the resolved framework role;
#     each title can be edited or removed.
#  4. Imported People — every HRIS-managed Person with their resolved
#     mapping/assignment status (computed via {Integrations::HrisPersonRow}).
#
# Every mapping edit goes through one shared modal
# ({Views::Integrations::HrisMappingModal}), prefilled from its trigger.
#
class Views::Integrations::HrisView < Views::Base
  SECONDARY_BUTTON_CLASSES = Components::Kit::Button.classes(variant: :outline, size: :sm)

  CHIP_CLASSES = "inline-flex items-center rounded-sm text-xs " \
                 "bg-neutral-subtle text-muted"

  # @param hris_config [HrisConfig]
  # @param hris_credentials_present [Boolean]
  # @param person_rows [Array<Integrations::HrisPersonRow>]
  # @param role_mapping_rows [Array<Hash>] each entry: { mapping:, role:, status_label:, status_variant: }
  # @param unmapped_titles [Array<Integrations::HrisTitleResolution::Title>]
  # @param mapping_options [Hash] roles, level ordinals by role code, HRIS
  #   titles, and whether a level column is configured — see
  #   {Views::Integrations::HrisMappingModal}
  # @param can_edit_mappings [Boolean]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(hris_config:, hris_credentials_present:, person_rows:, role_mapping_rows:,
                 unmapped_titles: [], mapping_options: {}, can_edit_mappings: false,
                 user: nil, current_tenant: nil, tenants: [])
    @hris_config = hris_config
    @hris_credentials_present = hris_credentials_present
    @person_rows = person_rows
    @role_mapping_rows = role_mapping_rows
    @unmapped_titles = unmapped_titles
    @mapping_options = mapping_options
    @can_edit_mappings = can_edit_mappings
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :integrations,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-6xl mx-auto space-y-10",
          data: { controller: "modal", action: "keydown.esc@window->modal#escape" }) do
        page_header
        configuration_section
        unmapped_titles_section
        role_mappings_section
        people_section
        render Views::Integrations::HrisMappingModal.new(**@mapping_options) if @can_edit_mappings
      end
    end
  end

  private

  # ── Header ──

  def page_header
    div(class: "mb-6") do
      a(
        href: tenant_integrations_path,
        class: "text-sm text-muted hover:text-default transition-colors"
      ) { plain "\u2190 Back to Integrations" }

      div(class: "mt-2 flex items-center gap-3") do
        h1(class: "text-2xl font-bold text-default") { "HRIS Integration" }
        render Components::Kit::Badge.new(provider_label, variant: :info)
      end
      p(class: "mt-1 text-sm text-muted") do
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
    div(class: "mt-6 pt-6 border-t border-default") do
      form(
        action: sync_tenant_integration_path("hris"),
        method: "post",
        class: "flex items-center gap-4"
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

        render Components::Kit::Button.new(tone: :brand, type: :submit, disabled: !sync_ready?) { "Sync now" }

        unless sync_ready?
          p(class: "text-xs text-muted") do
            plain "Configure provider, credentials, and enable sync to trigger an on-demand sync."
          end
        end
      end
    end
  end

  # ── Unmapped titles ──

  def unmapped_titles_section
    return if @unmapped_titles.empty?

    div(id: "unmapped-titles") do
      render Components::Kit::SectionHeading.new(
        "Unmapped titles",
        subtitle: "#{@unmapped_titles.size} HRIS #{'title'.pluralize(@unmapped_titles.size)} " \
                  "no mapping covers. The sync skips the people holding them."
      )

      render Components::Kit::Card.new(variant: :flush) do |card|
        card.body do
          div(class: "overflow-x-auto") do
            table(class: "min-w-full text-sm") do
              thead(class: "bg-subtle") do
                tr do
                  th_cell("HRIS title")
                  th_cell("People")
                  th_cell("HRIS level")
                  th_cell("Needs attention", hide_below_sm: true)
                  th_cell("Action", sr_only: true, hide_below_sm: true) if @can_edit_mappings
                end
              end
              tbody(class: "divide-y divide-default") do
                @unmapped_titles.each { |entry| unmapped_title_row(entry) }
              end
            end
          end
        end
      end
    end
  end

  def unmapped_title_row(entry)
    tr(data: { unmapped_title: entry.title }) do
      # Below `sm` the note and the action move under the title: off to the
      # right of a scrolled table, nobody on a phone would find them.
      td_cell do
        span(class: "font-medium") { entry.title }
        div(class: "sm:hidden mt-1 space-y-2") do
          stale_note(entry, placeholder: false)
          map_button(entry)
        end
      end
      td_cell { span(title: entry.rows.map { |row| row.person.name }.join(", ")) { entry.people_count.to_s } }
      td_cell { entry.hris_levels.any? ? entry.hris_levels.map { |l| "L#{l}" }.join(", ") : "\u2014" }
      td_cell(hide_below_sm: true) { stale_note(entry) }
      td_cell(hide_below_sm: true) { map_button(entry) } if @can_edit_mappings
    end
  end

  def map_button(entry)
    return unless @can_edit_mappings

    mapping_trigger("Map\u2026", title: entry.title,
      aria_label: "Map #{entry.title} to a role", classes: SECONDARY_BUTTON_CLASSES)
  end

  # The people the sync leaves on an assignment an earlier title gave them —
  # the reason this card exists.
  def stale_note(entry, placeholder: true)
    stale = entry.rows.select(&:stale_assignment?)
    if stale.empty?
      span(class: "text-subtle") { "\u2014" } if placeholder
      return
    end

    ul(class: "space-y-0.5") do
      stale.each do |row|
        li(class: "text-warning") do
          plain "#{row.person.name} is still on #{row.assigned_label} from an earlier title"
        end
      end
    end
  end

  # ── Role Mappings ──

  def role_mappings_section
    div do
      div(class: "flex items-end justify-between gap-4") do
        render Components::Kit::SectionHeading.new(
          "Role Mappings",
          subtitle: "How HRIS job titles are translated into framework roles and levels"
        )
        if @can_edit_mappings
          div(class: "mb-4 shrink-0") do
            mapping_trigger("Add mapping", title: "", aria_label: nil,
              classes: SECONDARY_BUTTON_CLASSES)
          end
        end
      end

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
        thead(class: "bg-subtle") do
          tr do
            th_cell("HRIS titles")
            th_cell("Framework role")
            th_cell("Level")
            th_cell("Status")
          end
        end
        tbody(class: "divide-y divide-default") do
          @role_mapping_rows.each { |row| role_mapping_row(row) }
        end
      end
    end
  end

  def role_mapping_row(row)
    tr do
      td_cell { titles_list(row[:mapping]) }
      td_cell { framework_role_cell(row) }
      td_cell { level_ordinal_cell(row[:mapping]) }
      td_cell { render Components::Kit::Badge.new(row[:status_label], variant: row[:status_variant]) }
    end
  end

  def titles_list(mapping)
    div(class: "flex flex-wrap gap-1") do
      Array(mapping.hris_titles).each do |title|
        if @can_edit_mappings
          editable_chip(title, mapping)
        else
          span(class: "#{CHIP_CLASSES} px-2 py-0.5") { title }
        end
      end
    end
  end

  # The chip opens the mapping modal for its title; the × removes it.
  def editable_chip(title, mapping)
    span(class: CHIP_CLASSES, data: { mapped_title: title }) do
      mapping_trigger(title, title: title, role: mapping.framework_role_code, level: mapping.level_ordinal,
        aria_label: "Edit mapping for #{title}",
        classes: "px-2 py-0.5 rounded-l-sm hover:bg-neutral-muted cursor-pointer " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-focus")
      form(action: tenant_hris_title_mapping_path, method: "post", class: "contents") do
        input(type: "hidden", name: "_method", value: "delete")
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "hris_title_mapping[title]", value: title)
        button(
          type: "submit",
          aria: { label: "Remove mapping for #{title}" },
          class: "px-1.5 py-0.5 rounded-r-sm text-muted hover:text-danger hover:bg-neutral-muted cursor-pointer " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-focus"
        ) { "\u00D7" }
      end
    end
  end

  # A button that opens the shared mapping modal, prefilled from its dataset.
  # A blank `title` is "Add mapping"; any other title is locked, since editing
  # a mapping moves that title rather than renaming it.
  def mapping_trigger(label, title:, classes:, aria_label:, role: nil, level: nil)
    button(
      type: "button",
      class: classes,
      aria: { label: aria_label }.compact,
      data: {
        action: "click->modal#open",
        modal_target_id: Views::Integrations::HrisMappingModal::ID,
        hris_mapping_title: title,
        hris_mapping_role: role.to_s,
        hris_mapping_level: level.to_s
      }
    ) { label }
  end

  def framework_role_cell(row)
    if row[:role]
      span(class: "font-mono text-default") { row[:mapping].framework_role_code }
      span(class: "ml-2 text-muted") { row[:role].name }
    else
      span(class: "font-mono text-default") { row[:mapping].framework_role_code }
    end
  end

  def level_ordinal_cell(mapping)
    if mapping.level_ordinal
      span(class: "font-mono") { "L#{mapping.level_ordinal}" }
    else
      span(class: "text-xs text-muted") { "from custom column" }
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
        thead(class: "bg-subtle") do
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
        tbody(class: "divide-y divide-default") do
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
      div(class: "font-medium text-default") { person.name }
      div(class: "text-xs text-muted") { person.email }
    end
  end

  def mapped_role_cell(row)
    if row.mapping
      span(class: "font-mono") { row.mapped_role_code }
    else
      span(class: "text-subtle") { "\u2014" }
    end
  end

  # ── Helpers ──

  def empty_state(text)
    div(class: "px-6 py-10 text-center text-sm text-muted") { text }
  end

  # `sr_only:` hides the label but keeps it for screen readers. The cell is
  # then `relative`, because an `sr-only` span is absolutely positioned: with
  # no positioned ancestor inside the table's scroller it escapes to the
  # document and widens the whole page on a phone.
  def th_cell(label, sr_only: false, hide_below_sm: false)
    th(
      scope: "col",
      class: [ "px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted",
               ("relative" if sr_only), ("max-sm:hidden" if hide_below_sm) ].compact.join(" ")
    ) { sr_only ? span(class: "sr-only") { label } : label }
  end

  def td_cell(hide_below_sm: false, &block)
    td(class: [ "px-4 py-3 align-top text-default", ("max-sm:hidden" if hide_below_sm) ].compact.join(" "),
       &block)
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
