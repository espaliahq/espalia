# frozen_string_literal: true

# Renders a pending illustration suggestion as a ghost entry in the
# expanded row.
#
# Visually resembles an IllustrationFrame but with amber wavy underline
# decoration to signal its tentative status. The pencil icon allows:
# - Original author: amend the pending suggestion
# - Other collaborators: submit an alternative suggestion
#
class Views::Frameworks::Explorer::PendingIllustrationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::ApprovalKebabItems
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param suggestion [FrameworkState::SuggestedEdit] kind: "create", target: role_illustration
  # @param framework_id [String] UUID of the framework
  # @param is_author [Boolean] true if the current user authored this suggestion
  # @param error [String, nil] a failed inline-amend message, surfaced in the
  #   frame (a bodyless error response would blank the ghost to
  #   "Content missing")
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] gates
  #   the inline Approve/Reject kebab (§12). Controller frame re-renders must
  #   re-thread it (Hard-Won Lesson 13/16 class).
  # @param attempted_value [String, nil] the value a rejected amend carried —
  #   the shared editor re-opens seeded with it so nothing typed is lost
  def initialize(suggestion:, framework_id:, is_author: false, error: nil,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 attempted_value: nil)
    @suggestion = suggestion
    @framework_id = framework_id
    @is_author = is_author
    @error = error
    @approval_authority = approval_authority
    @attempted_value = attempted_value
    @attrs = (suggestion.proposed_attributes || {}).symbolize_keys
  end

  def view_template
    turbo_frame_tag("pending-suggestion-#{@suggestion.suggestion_id}") do
      li(
        class: "group/ill relative text-xs text-gray-600 dark:text-gray-400",
        data: editor_data
      ) do
        error_line if @error.present?
        display_mode
      end
    end
  end

  private

  def error_line
    div(class: "pl-2") { render_field_editor_error(@error) }
  end

  # The author amends their own pending proposal (via the amend endpoint);
  # anyone else submits an alternative through the illustration create endpoint.
  # Either way the result is a pending suggestion, so the outcome is fixed —
  # never derived from the viewer's authority.
  def editor_data
    common = {
      value: @error ? @attempted_value.to_s : @attrs[:description].to_s,
      label: @is_author ? "Amend suggestion" : "Alternative illustration",
      outcome: "propose",
      rows: 3,
      form_class: "pl-2",
      error: @error
    }
    if @is_author
      field_editor_data(
        action: amend_framework_suggestion_path(
          framework_id: @framework_id, id: @suggestion.suggestion_id
        ),
        field: "suggestion[suggested_value]",
        submit_label: "Save",
        # inline=1 re-renders this ghost frame in place rather than taking the
        # amend endpoint's detail-page redirect (Hard-Won Lesson 20).
        extra: { "inline" => "1" },
        **common
      )
    else
      field_editor_data(
        action: framework_illustrations_path(framework_id: @framework_id),
        field: "illustration[description]",
        method: "post",
        submit_label: "Suggest alternative",
        extra: {
          "illustration[expectation_id]" => @suggestion.parent_id,
          "illustration[role_id]" => @attrs[:role_id]
        },
        **common
      )
    end
  end

  def display_mode
    decoration = suggestion_text_classes(pending_edit_count: 1)

    div(
      class: "flex items-start gap-1.5 pl-2",
      data: { editor_display: true }
    ) do
      # Amber marker — this entry is a pending proposal.
      render_illustration_marker("bg-amber-400")
      span(class: "flex-1") do
        with_suggestion_click_affordance(@suggestion.suggestion_id) do
          span(class: decoration) { @attrs[:description] }
        end
      end
      edit_button
      # Kebab last — always the right-most control (phlex-views.md).
      approval_kebab if approvable?
    end
  end

  # A pending NEW illustration is approvable from the grid like a pending edit
  # — same tier, same §12 machinery (approval stages the add; the card remains
  # the escape hatch for discussion).
  def approvable?
    @approval_authority.can_approve?("role_illustration")
  end

  def approval_kebab
    render_approval_kebab(
      framework_id: @framework_id,
      suggestion_id: @suggestion.suggestion_id,
      change_label: "new illustration",
      entity_label: "new illustration",
      preview: @attrs[:description].to_s,
      trigger_label: "New-illustration suggestion actions",
      reveal_classes: "opacity-0 group-hover/ill:opacity-100 " \
                      "group-focus-within/ill:opacity-100"
    )
  end

  def edit_button
    button(
      type: "button",
      class: "opacity-0 group-hover/ill:opacity-100 " \
             "group-focus-within/ill:opacity-100 focus-visible:opacity-100 " \
             "transition-opacity text-gray-400 hover:text-primary shrink-0 mt-0.5",
      data: { action: "field-editor#open" },
      aria_label: @is_author ? "Amend suggestion" : "Suggest alternative"
    ) do
      render_inline_editor_pencil_icon
    end
  end
end
