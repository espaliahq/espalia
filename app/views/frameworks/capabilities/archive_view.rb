# frozen_string_literal: true

# Archive-capability form. Captures the migration mapping as-we-go for a
# pre-draft capability (mapping type + survivor); a capability added in the
# current draft has nothing to migrate, so the mapping section is omitted.
# Submits to {Frameworks::CapabilityArchivesController#create}.
class Views::Frameworks::Capabilities::ArchiveView < Views::Base
  # Mapping types meaningful when retiring an existing capability, with the
  # subset that needs a surviving capability to carry ratings forward.
  MAPPING_TYPES = [
    [ "evolved", "Evolved — broadened/narrowed into a survivor (ratings carry forward)" ],
    [ "split",   "Split — work moved into a survivor (add more on the publish review)" ],
    [ "archived", "Archived — retired with no replacement (ratings surface to relink)" ]
  ].freeze
  SURVIVOR_TYPES = %w[evolved split].freeze

  # @param framework [FrameworkState::Framework]
  # @param capability [FrameworkState::Capability]
  # @param needs_mapping [Boolean]
  # @param survivors [Enumerable<FrameworkState::Capability>]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(framework:, capability:, needs_mapping:, survivors:,
                 user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @capability = capability
    @needs_mapping = needs_mapping
    @survivors = survivors
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-xl mx-auto px-4 py-8 space-y-6") do
        header
        archive_form
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
        plain "Archive “#{@capability.name}”"
      end
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        if @needs_mapping
          plain "Choose what happens to existing ratings on this capability. You can " \
                "revise this on the publish review before it goes live."
        else
          plain "This capability was added in the current draft, so there are no " \
                "existing ratings to migrate."
        end
      end
    end
  end

  def archive_form
    form(
      action: framework_capability_archive_path(@framework.framework_id, @capability.capability_id),
      method: "post",
      class: "space-y-6",
      data: { controller: "mapping-form" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      reason_field
      mapping_fields if @needs_mapping
      actions
    end
  end

  def reason_field
    div do
      label(for: "archive_reason",
            class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Reason" }
      textarea(
        id: "archive_reason", name: "archive[reason]", rows: "2",
        class: input_classes,
        placeholder: "Why is this capability being retired?"
      )
    end
  end

  def mapping_fields
    div(class: "space-y-4 rounded-md border border-gray-200 dark:border-gray-700 p-4") do
      div do
        label(for: "archive_mapping_type",
              class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Migration mapping" }
        select(
          id: "archive_mapping_type", name: "archive[mapping_type]",
          class: input_classes,
          data: { mapping_form_target: "type", action: "change->mapping-form#typeChanged" }
        ) do
          MAPPING_TYPES.each { |value, text| option(value: value) { text } }
        end
      end

      div(data: { mapping_form_target: "survivor" }) do
        label(for: "archive_to_stable_id",
              class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Surviving capability" }
        select(
          id: "archive_to_stable_id", name: "archive[to_stable_id]",
          class: input_classes
        ) do
          option(value: "") { "— select —" }
          @survivors.each { |cap| option(value: cap.stable_id) { cap.name } }
        end
      end
    end
  end

  def actions
    div(class: "flex items-center gap-3") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-red-700 transition-colors"
      ) { "Archive capability" }
      a(href: edit_framework_path(@framework.framework_id),
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200") { "Cancel" }
    end
  end

  def input_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
