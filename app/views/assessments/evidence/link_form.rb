# frozen_string_literal: true

# Page-level modal for linking an existing evidence item to an ADDITIONAL
# (capability, level) coordinate — one piece of evidence can demonstrate
# several expectations. Rendered once per assessment page; the kebab "Link
# to another capability" menu item on each evidence card opens it via the
# evidence-link-form Stimulus controller, priming the evidence_id and the
# originating cell (so the server re-renders the right list afterward).
#
# The capability list comes pre-grouped by category so the user can scan to
# the target capability without leaving the modal. Levels match the
# assessee's role — the same set the matrix renders columns for.
#
class Views::Assessments::Evidence::LinkForm < Views::Base
  # The form's action URL is filled in dynamically by the
  # `evidence-link-form` Stimulus controller per click — each evidence item
  # has a different `:id` in the URL — so the assignment id only needs to
  # live as `data-evidence-link-form-assessment-id-value` on the
  # controller's element (set by ShowView/ManagerShowView).
  #
  # @param categories [Array<Hash>] from MatrixDataBuilder, [{ category:, capabilities: [...] }]
  # @param merged_levels [Array<Hash>] from MatrixDataBuilder
  def initialize(categories:, merged_levels:)
    @categories = categories
    @merged_levels = merged_levels
  end

  def view_template
    div(
      id: "evidence-link-modal",
      data: { evidence_link_form_target: "modal" },
      class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
      role: "dialog",
      aria_modal: "true",
      aria_labelledby: "evidence-link-form-title"
    ) do
      div(
        class: "w-full max-w-md rounded-lg bg-white dark:bg-gray-900 p-5 shadow-xl",
        data: { evidence_link_form_target: "panel" }
      ) do
        header
        form_body
      end
    end
  end

  private

  def header
    div(class: "flex items-baseline justify-between mb-3") do
      h2(id: "evidence-link-form-title",
         class: "text-lg font-semibold text-gray-900 dark:text-white") { "Link evidence" }
      button(
        type: "button",
        class: "text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 text-xl leading-none",
        data: { action: "click->evidence-link-form#close" },
        aria: { label: "Close" }
      ) { "×" }
    end
    p(class: "mb-3 text-xs text-gray-600 dark:text-gray-300") do
      "Attach this evidence to another capability × level. It will appear in both places."
    end
  end

  def form_body
    form(
      action: "#",
      method: "post",
      data: { evidence_link_form_target: "form",
              action: "submit->evidence-link-form#submit" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "evidence[from_capability_stable_id]",
            data: { evidence_link_form_target: "fromCapabilityField" })
      input(type: "hidden", name: "evidence[from_level_ordinal]",
            data: { evidence_link_form_target: "fromLevelField" })
      capability_field
      level_field
      rationale_field
      footer
    end
  end

  def capability_field
    div(class: "mb-3") do
      label(for: "evidence_link_capability_field", class: label_classes) { "Link to capability" }
      select(
        id: "evidence_link_capability_field",
        name: "evidence[capability_stable_id]",
        class: input_classes,
        required: true,
        data: { evidence_link_form_target: "capabilitySelect" }
      ) do
        @categories.each do |cat_data|
          optgroup(label: cat_data[:category].name) do
            cat_data[:capabilities].each do |cap_data|
              cap = cap_data[:capability]
              option(value: cap.stable_id) { cap.name }
            end
          end
        end
      end
    end
  end

  def level_field
    div(class: "mb-3") do
      label(for: "evidence_link_level_field", class: label_classes) { "At level" }
      select(
        id: "evidence_link_level_field",
        name: "evidence[level_ordinal]",
        class: input_classes,
        required: true,
        data: { evidence_link_form_target: "levelSelect" }
      ) do
        @merged_levels.each do |level|
          option(value: level[:ordinal]) do
            "L#{level[:ordinal]} — #{level[:level_title].presence || level[:level_code]}"
          end
        end
      end
    end
  end

  def rationale_field
    div(class: "mb-3") do
      label(for: "evidence_link_rationale_field", class: label_classes) do
        "Why does it also apply here? (optional)"
      end
      textarea(id: "evidence_link_rationale_field",
               name: "evidence[rationale]",
               rows: 3, class: input_classes) { "" }
    end
  end

  def footer
    div(class: "mt-4 flex items-center justify-end gap-2") do
      button(
        type: "button",
        class: "px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 " \
               "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800",
        data: { action: "click->evidence-link-form#close" }
      ) { "Cancel" }
      button(
        type: "submit",
        class: "px-3 py-1.5 text-sm rounded-md bg-primary text-white hover:bg-primary/90"
      ) { "Link evidence" }
    end
  end

  def label_classes
    "block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1"
  end

  def input_classes
    "w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-2.5 py-1.5 text-sm text-gray-900 dark:text-white " \
      "focus:outline-none focus:ring-2 focus:ring-primary"
  end
end
