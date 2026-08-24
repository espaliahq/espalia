# frozen_string_literal: true

# Renders a pending behavioural-expectation creation suggestion as an editable
# ghost in an otherwise-empty matrix cell — so a proposed expectation is visible
# in the grid (not just the feed) and follows the same inline-edit pattern as
# every other suggestion. The amber wavy underline is the explorer's pending
# signal; a hover-revealed pencil (immediately right of the text, per the
# inline-edit convention) opens an inline form pre-filled with the current value.
#
# Both author and non-author submit to the same create endpoint
# (ExpectationsController#create → SetBehaviouralExpectation): the author's
# resubmit *amends* their pending proposal (amend-on-duplicate), a non-author's
# becomes their own alternative proposal. So the cell never shows a separate
# "+ Add expectation" affordance while a proposal exists.
class Views::Frameworks::Explorer::PendingExpectationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::ApprovalKebabItems

  # @param suggestion [FrameworkState::SuggestedEdit] kind: "create", target: behavioural_expectation
  # @param framework_id [String]
  # @param level_ordinal [Integer] the cell's level ordinal
  # @param is_author [Boolean] whether the viewer authored this proposal
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] gates
  #   the inline Approve/Reject kebab (§12). Form submits are full navigations
  #   (`_top`), so no controller re-threading is needed here.
  def initialize(suggestion:, framework_id:, level_ordinal:, is_author: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @suggestion = suggestion
    @framework_id = framework_id
    @level_ordinal = level_ordinal
    @is_author = is_author
    @approval_authority = approval_authority
    @attrs = (suggestion.proposed_attributes || {}).symbolize_keys
  end

  def view_template
    # `group/ine` so the shared inline-edit pencil reveals on hover.
    div(class: "group/ine relative mb-1", data: { controller: "inline-editor" }) do
      display
      edit_form
    end
  end

  private

  # An amended create carries its current value in suggested_value (the amend
  # only updates that field); fall back to the original proposed description.
  def proposed_text
    @suggestion.suggested_value.presence || @attrs[:description]
  end

  # Text then pencil, in a flex row — the pencil sits immediately to the right of
  # the text (no flex-grow on the text), matching every inline-edit affordance.
  def display
    div(class: "flex items-start gap-1", data: { inline_editor_target: "display" }) do
      with_suggestion_click_affordance(@suggestion.suggestion_id) do
        span(class: "text-sm text-gray-700 dark:text-gray-300 " \
                    "#{suggestion_text_classes(pending_edit_count: 1)}") { proposed_text }
      end
      render_inline_editor_pencil(aria_label: @is_author ? "Amend suggestion" : "Suggest alternative")
      # Kebab last — always the right-most control (phlex-views.md).
      approval_kebab if approvable?
    end
  end

  # A pending NEW expectation is approvable from the grid like a pending edit
  # — expectation tier, same §12 machinery (approval stages the add into a
  # draft; publish remains the gate).
  def approvable?
    @approval_authority.can_approve?("behavioural_expectation")
  end

  def approval_kebab
    render_approval_kebab(
      framework_id: @framework_id,
      suggestion_id: @suggestion.suggestion_id,
      change_label: "new expectation",
      entity_label: "new expectation",
      preview: proposed_text.to_s,
      trigger_label: "New-expectation suggestion actions",
      reveal_classes: "opacity-0 group-hover/ine:opacity-100 " \
                      "group-focus-within/ine:opacity-100"
    )
  end

  # Submits to the create endpoint; SetBehaviouralExpectation amends the author's
  # own pending proposal or records a non-author's alternative. Redirects (full
  # navigation) like the "+ Add expectation" form, so data-turbo-frame="_top".
  def edit_form
    form(
      class: "hidden mt-1",
      method: "post",
      action: framework_expectations_path(framework_id: @framework_id),
      data: { inline_editor_target: "form", turbo_frame: "_top" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "behavioural_expectation[capability_id]", value: @suggestion.parent_id)
      input(type: "hidden", name: "behavioural_expectation[level_ordinal]", value: @level_ordinal)

      textarea(
        class: "w-full text-xs border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
        rows: "3",
        name: "behavioural_expectation[description]",
        data: { inline_editor_target: "input" }
      ) { proposed_text }

      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
        ) { @is_author ? "Save" : "Suggest alternative" }
        button(
          type: "button",
          class: "text-xs px-2 py-0.5 rounded border border-gray-300 dark:border-gray-600 " \
                 "text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800",
          data: { action: "inline-editor#cancel" }
        ) { "Cancel" }
      end
    end
  end
end
