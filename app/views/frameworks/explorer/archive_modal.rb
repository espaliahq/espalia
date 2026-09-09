# frozen_string_literal: true

# Shared archive modal for the Framework Explorer (edit mode). One instance
# per page; each capability's row-actions kebab opens it, passing the
# capability's id/name and whether it needs a migration mapping via the
# trigger dataset (read by the `archive-form` Stimulus controller).
#
# Captures the migration mapping as-we-go for a pre-draft capability — only
# Evolve (carry ratings to a survivor) or Archive (retire). Splitting a
# capability is a separate action, so it is not offered here. The mapping
# section is hidden for a capability added in the current draft (nothing to
# migrate). Submits to {Frameworks::CapabilityArchivesController#create}.
class Views::Frameworks::Explorer::ArchiveModal < Views::Base
  MAPPING_TYPES = [
    [ "evolved",  "Evolve — ratings carry forward to a survivor" ],
    [ "archived", "Archive — retire with no replacement" ]
  ].freeze

  # @param framework_id [String]
  # @param survivors [Array<Hash>] { name:, stable_id: } survivor candidates
  def initialize(framework_id:, survivors: [])
    @framework_id = framework_id
    @survivors = survivors
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "archive-capability-modal", title: "Archive capability", standalone: false
    ) do |m|
      m.body { archive_form }
    end
  end

  private

  def archive_form
    form(
      action: framework_capability_archives_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: { controller: "archive-form tree-scope-fields",
              action: "turbo:submit-end->modal#submitted" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "archive[capability_id]", data: { archive_form_target: "capabilityId" })

      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        plain "Archiving "
        span(class: "font-semibold text-gray-900 dark:text-white",
             data: { archive_form_target: "title" }) { "this capability" }
        plain "."
      end

      reason_field
      mapping_fields
      actions
    end
  end

  def reason_field
    div do
      label(for: "archive_reason",
            class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Reason" }
      textarea(
        id: "archive_reason", name: "archive[reason]", rows: "2",
        class: field_classes, placeholder: "Why is this capability being retired?"
      )
    end
  end

  # Hidden until the kebab signals a pre-draft capability (needs a mapping).
  def mapping_fields
    div(class: "hidden space-y-3 rounded-md border border-gray-200 dark:border-gray-700 p-3",
        data: { archive_form_target: "mappingSection" }) do
      div do
        label(for: "archive_mapping_type",
              class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Migration mapping" }
        select(
          id: "archive_mapping_type", name: "archive[mapping_type]", class: field_classes,
          data: { archive_form_target: "type", action: "change->archive-form#typeChanged" }
        ) do
          MAPPING_TYPES.each { |value, text| option(value: value) { text } }
        end
      end

      div(data: { archive_form_target: "survivor" }) do
        label(for: "archive_to_stable_id",
              class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Surviving capability" }
        select(id: "archive_to_stable_id", name: "archive[to_stable_id]", class: field_classes) do
          option(value: "") { "— select —" }
          @survivors.each { |cap| option(value: cap[:stable_id]) { cap[:name] } }
        end
      end
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-red-700 transition-colors"
      ) { "Archive capability" }
      button(
        type: "button", data: { action: "click->modal#close" },
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
      ) { "Cancel" }
    end
  end

  def field_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
