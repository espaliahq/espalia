# frozen_string_literal: true

# Page-level modal form for recording new evidence.
#
# Rendered once per assessment page. The "+ Add evidence" affordance on
# each cell sets hidden capability_stable_id / level_ordinal fields
# (via the evidence_form Stimulus controller) and toggles the modal
# open. Submission goes to {Assessments::EvidenceController#create} as
# a regular Rails form — server returns Turbo Streams that replace the
# specific evidence list and refresh the activity feed.
#
class Views::Assessments::Evidence::Form < Views::Base
  TYPE_OPTIONS = [
    [ "Project outcome",   "project_outcome" ],
    [ "Code review",       "code_review" ],
    [ "Design review",     "design_review" ],
    [ "Customer feedback", "customer_feedback" ],
    [ "Peer feedback",     "peer_feedback" ],
    [ "Incident response", "incident_response" ],
    [ "Presentation",      "presentation" ],
    [ "Mentoring",         "mentoring" ],
    [ "Observation",       "observation" ],
    [ "Other (describe)",  "other" ]
  ].freeze

  SYSTEM_OPTIONS = [
    [ "(none)",     "" ],
    [ "GitHub",     "github" ],
    [ "GitLab",     "gitlab" ],
    [ "Linear",     "linear" ],
    [ "Jira",       "jira" ],
    [ "Slack",      "slack" ],
    [ "Notion",     "notion" ],
    [ "Google Doc", "google_doc" ],
    [ "Figma",      "figma" ],
    [ "Other",      "other" ]
  ].freeze

  # @param assessment_id [String]
  def initialize(assessment_id:)
    @assessment_id = assessment_id
  end

  def view_template
    # NOTE: data-controller="evidence-form" intentionally lives on a higher
    # ancestor (the page wrapper) — see Views::Assessments::ShowView. The
    # trigger buttons inside the matrix frame are sibling-cousins of this
    # modal, not descendants, so the controller must enclose both.
    div(
      id: "evidence-form-modal",
      data: { evidence_form_target: "modal" },
      class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
      role: "dialog",
      aria_modal: "true",
      aria_labelledby: "evidence-form-title"
    ) do
      div(
        class: "w-full max-w-md rounded-lg bg-white dark:bg-gray-900 p-5 shadow-xl",
        data: { evidence_form_target: "panel" }
      ) do
        header
        form_body
      end
    end
  end

  private

  def header
    div(class: "flex items-baseline justify-between mb-3") do
      h2(id: "evidence-form-title",
         class: "text-lg font-semibold text-gray-900 dark:text-white") { "Add evidence" }
      button(
        type: "button",
        class: "text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 text-xl leading-none",
        data: { action: "click->evidence-form#close" },
        aria: { label: "Close" }
      ) { "×" }
    end
  end

  def form_body
    form(
      action: assessment_evidence_index_path(@assessment_id),
      method: "post",
      data: {
        evidence_form_target: "form",
        action: "turbo:submit-end->evidence-form#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "evidence[capability_stable_id]",
            data: { evidence_form_target: "capabilityField" })
      input(type: "hidden", name: "evidence[level_ordinal]",
            data: { evidence_form_target: "levelField" })

      type_field
      custom_label_field
      title_field
      content_field
      external_reference_fields
      footer
    end
  end

  def type_field
    div(class: "mb-3") do
      label(for: "evidence_type_field", class: label_classes) { "Type" }
      select(id: "evidence_type_field", name: "evidence[evidence_type]",
             class: input_classes,
             data: { action: "change->evidence-form#typeChanged",
                     evidence_form_target: "typeSelect" }) do
        TYPE_OPTIONS.each do |label_text, value|
          option(value: value) { label_text }
        end
      end
    end
  end

  def custom_label_field
    div(class: "mb-3 hidden", data: { evidence_form_target: "customLabelWrapper" }) do
      label(for: "evidence_custom_type_label_field", class: label_classes) { "Describe the type" }
      input(id: "evidence_custom_type_label_field", type: "text",
            name: "evidence[custom_type_label]", maxlength: 60, class: input_classes)
    end
  end

  def title_field
    div(class: "mb-3") do
      label(for: "evidence_title_field", class: label_classes) { "Title (optional)" }
      input(id: "evidence_title_field", type: "text", name: "evidence[title]",
            maxlength: 120, class: input_classes)
    end
  end

  def content_field
    div(class: "mb-3") do
      label(for: "evidence_content_field", class: label_classes) { "What happened?" }
      textarea(id: "evidence_content_field", name: "evidence[content]",
               rows: 4, required: true, class: input_classes) { "" }
    end
  end

  def external_reference_fields
    div(class: "mb-3 grid grid-cols-2 gap-2") do
      div do
        label(for: "evidence_ref_system_field", class: label_classes) { "Link to (optional)" }
        select(id: "evidence_ref_system_field",
               name: "evidence[external_reference][system]", class: input_classes) do
          SYSTEM_OPTIONS.each do |label_text, value|
            option(value: value) { label_text }
          end
        end
      end
      div do
        label(for: "evidence_ref_url_field", class: label_classes) { "URL" }
        input(id: "evidence_ref_url_field", type: "url",
              name: "evidence[external_reference][url]",
              placeholder: "https://", class: input_classes)
      end
    end
  end

  def footer
    div(class: "mt-4 flex items-center justify-end gap-2") do
      button(
        type: "button",
        class: "px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 " \
               "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800",
        data: { action: "click->evidence-form#close" }
      ) { "Cancel" }
      button(
        type: "submit",
        class: "px-3 py-1.5 text-sm rounded-md bg-primary text-white hover:bg-primary/90"
      ) { "Save evidence" }
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
