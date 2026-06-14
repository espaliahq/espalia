# frozen_string_literal: true

# Publish-review screen. The owner/editor validates the as-we-go migration
# mappings for every capability being retired in the draft — editing any that
# need it — then confirms the publish. Reached from the explorer's Publish
# button; submits to {Frameworks::PublicationsController#create}.
class Views::Frameworks::PublicationReviewView < Views::Base
  # Mapping types meaningful when retiring a capability; the subset needing a
  # surviving capability is wired to the mapping-form Stimulus controller.
  MAPPING_TYPES = [
    [ "evolved", "Evolved — into a survivor" ],
    [ "archived", "Archived — no replacement" ]
  ].freeze

  # @param framework [FrameworkState::Framework]
  # @param retiring [Array<Hash>] { capability:, mapping: } for each retiring capability
  # @param survivors [Array<Hash>] { name:, stable_id: } survivor candidates
  def initialize(framework:, retiring:, survivors:, user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @retiring = retiring
    @survivors = survivors
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-2xl mx-auto px-4 py-8 space-y-6") do
        header
        retiring_section
        confirm_section
      end
    end
  end

  private

  def header
    div do
      a(href: edit_framework_path(@framework.framework_id),
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200") do
        plain "← Back to #{@framework.name}"
      end
      h1(class: "mt-2 text-2xl font-bold text-gray-900 dark:text-white") do
        plain "Publish v#{@framework.draft_version}"
      end
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        plain "Review what happens to retired capabilities, then publish. Publishing " \
              "makes the draft live and migrates in-flight assessments — it cannot be undone."
      end
    end
  end

  def retiring_section
    if @retiring.empty?
      p(class: "rounded-md bg-gray-50 dark:bg-gray-800 px-4 py-3 text-sm text-gray-600 dark:text-gray-300") do
        plain "No capabilities are being retired in this draft — nothing to migrate."
      end
      return
    end

    div(class: "space-y-3") do
      render Components::Kit::SectionHeading.new(
        "Retiring #{@retiring.size} #{'capability'.pluralize(@retiring.size)}",
        subtitle: "Confirm or change how each one's existing ratings migrate."
      )
      @retiring.each { |entry| mapping_row(entry[:capability], entry[:mapping]) }
    end
  end

  def mapping_row(capability, mapping)
    div(class: "rounded-md border #{mapping ? 'border-gray-200 dark:border-gray-700' : 'border-amber-300 dark:border-amber-700'} p-4") do
      div(class: "flex items-center justify-between") do
        span(class: "font-medium text-gray-900 dark:text-white") { capability.name }
        unless mapping
          span(class: "text-xs font-semibold text-amber-700 dark:text-amber-300") { "Needs a mapping" }
        end
      end
      mapping_form(capability, mapping)
    end
  end

  def mapping_form(capability, mapping)
    form(
      action: framework_migration_mappings_path(@framework.framework_id),
      method: "post",
      class: "mt-3 flex flex-wrap items-end gap-3",
      data: { controller: "mapping-form" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "migration_mapping[from_stable_id]", value: capability.stable_id)
      input(type: "hidden", name: "migration_mapping[mapping_id]", value: mapping&.mapping_id)

      type_select(mapping)
      survivor_select(mapping)
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-gray-900 dark:bg-gray-100 px-3 py-2 " \
               "text-sm font-semibold text-white dark:text-gray-900 hover:opacity-90 transition"
      ) { "Save mapping" }
    end
  end

  def type_select(mapping)
    div do
      label(class: "block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1") { "Mapping" }
      select(
        name: "migration_mapping[mapping_type]", class: field_classes,
        data: { mapping_form_target: "type", action: "change->mapping-form#typeChanged" }
      ) do
        MAPPING_TYPES.each do |value, text|
          option(value: value, selected: mapping&.mapping_type == value) { text }
        end
      end
    end
  end

  def survivor_select(mapping)
    div(data: { mapping_form_target: "survivor" }) do
      label(class: "block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1") { "Survivor" }
      select(name: "migration_mapping[to_stable_id]", class: field_classes) do
        option(value: "") { "— select —" }
        @survivors.each do |s|
          option(value: s[:stable_id], selected: mapping&.to_stable_id == s[:stable_id]) { s[:name] }
        end
      end
    end
  end

  def confirm_section
    form(
      action: framework_publication_path(@framework.framework_id),
      method: "post",
      class: "border-t border-gray-200 dark:border-gray-700 pt-6 flex items-center gap-3"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-primary/90 transition-colors"
      ) { "Confirm & publish v#{@framework.draft_version}" }
      a(href: edit_framework_path(@framework.framework_id),
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200") { "Cancel" }
    end
  end

  def field_classes
    "rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 " \
      "px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
