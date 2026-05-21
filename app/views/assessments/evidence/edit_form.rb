# frozen_string_literal: true

# Page-level modal form for editing an existing piece of evidence.
#
# Rendered once per assessment page. Kebab "Edit" items on evidence
# cards (rendered by {Views::Assessments::Evidence::Card}) carry the
# evidence's current field values in `data-evidence-edit-form-*-param`
# attributes; the {EvidenceEditFormController} reads them, stamps the
# form's action URL with the right `/evidence/:id` segment, prefills
# every input, and shows the modal.
#
# Submission goes to {Assessments::EvidenceController#update} via a
# PATCH (Rails' `_method` hidden field) and triggers a redirect back to
# the assessment page focused on the evidence's capability + category.
#
class Views::Assessments::Evidence::EditForm < Views::Base
  # The same option lists as {Form}. Duplicated rather than imported because
  # editing is a distinct UI surface and we don't want a rename in one to
  # silently re-label the other.
  TYPE_OPTIONS = [
    [ "Project outcome",   "project_outcome" ],
    [ "Code review",       "code_review" ],
    [ "Design review",     "design_review" ],
    [ "Customer feedback", "customer_feedback" ],
    [ "Peer feedback",     "peer_feedback" ],
    [ "Incident response", "incident_response" ],
    [ "Presentation",      "presentation" ],
    [ "Mentoring",         "mentoring" ],
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
    div(
      id: "evidence-edit-form-modal",
      data: { evidence_edit_form_target: "modal" },
      class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
      role: "dialog",
      aria_modal: "true",
      aria_labelledby: "evidence-edit-form-title"
    ) do
      div(
        class: "w-full max-w-md rounded-lg bg-white dark:bg-gray-900 p-5 shadow-xl",
        data: { evidence_edit_form_target: "panel" }
      ) do
        header
        form_body
      end
    end
  end

  private

  def header
    div(class: "flex items-baseline justify-between mb-3") do
      h2(id: "evidence-edit-form-title",
         class: "text-lg font-semibold text-gray-900 dark:text-white") { "Edit evidence" }
      button(
        type: "button",
        class: "text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 text-xl leading-none",
        data: { action: "click->evidence-edit-form#close" },
        aria: { label: "Close" }
      ) { "×" }
    end
  end

  def form_body
    # action is stamped at open-time by the controller with the right
    # `:id` segment; a placeholder here keeps the form valid before any
    # user has triggered open.
    form(
      action: assessment_evidence_path(@assessment_id, "__placeholder__"),
      method: "post",
      data: { evidence_edit_form_target: "form" }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

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
      label(for: "evidence_edit_type_field", class: label_classes) { "Type" }
      select(id: "evidence_edit_type_field", name: "evidence[evidence_type]",
             class: input_classes,
             data: { action: "change->evidence-edit-form#typeChanged",
                     evidence_edit_form_target: "typeSelect" }) do
        TYPE_OPTIONS.each do |label_text, value|
          option(value: value) { label_text }
        end
      end
    end
  end

  def custom_label_field
    div(class: "mb-3 hidden", data: { evidence_edit_form_target: "customLabelWrapper" }) do
      label(for: "evidence_edit_custom_type_label_field", class: label_classes) { "Describe the type" }
      input(id: "evidence_edit_custom_type_label_field", type: "text",
            name: "evidence[custom_type_label]", maxlength: 60, class: input_classes,
            data: { evidence_edit_form_target: "customLabelField" })
    end
  end

  def title_field
    div(class: "mb-3") do
      label(for: "evidence_edit_title_field", class: label_classes) { "Title (optional)" }
      input(id: "evidence_edit_title_field", type: "text", name: "evidence[title]",
            maxlength: 120, class: input_classes,
            data: { evidence_edit_form_target: "titleField" })
    end
  end

  def content_field
    div(class: "mb-3") do
      label(for: "evidence_edit_content_field", class: label_classes) { "What happened?" }
      textarea(id: "evidence_edit_content_field", name: "evidence[content]",
               rows: 4, required: true, class: input_classes,
               data: { evidence_edit_form_target: "contentField" }) { "" }
    end
  end

  def external_reference_fields
    div(class: "mb-3 grid grid-cols-2 gap-2") do
      div do
        label(for: "evidence_edit_ref_system_field", class: label_classes) { "Link to (optional)" }
        select(id: "evidence_edit_ref_system_field",
               name: "evidence[external_reference][system]", class: input_classes,
               data: { evidence_edit_form_target: "refSystemField" }) do
          SYSTEM_OPTIONS.each do |label_text, value|
            option(value: value) { label_text }
          end
        end
      end
      div do
        label(for: "evidence_edit_ref_url_field", class: label_classes) { "URL" }
        input(id: "evidence_edit_ref_url_field", type: "url",
              name: "evidence[external_reference][url]",
              placeholder: "https://", class: input_classes,
              data: { evidence_edit_form_target: "refUrlField" })
      end
    end
  end

  def footer
    div(class: "mt-4 flex items-center justify-end gap-2") do
      button(
        type: "button",
        class: "px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 " \
               "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800",
        data: { action: "click->evidence-edit-form#close" }
      ) { "Cancel" }
      button(
        type: "submit",
        class: "px-3 py-1.5 text-sm rounded-md bg-primary text-white hover:bg-primary/90"
      ) { "Save changes" }
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
