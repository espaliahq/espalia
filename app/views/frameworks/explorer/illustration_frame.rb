# frozen_string_literal: true

# Renders a single role illustration inside its Turbo Frame.
#
# Used both in the on-demand expanded row (ExpandedRow#expanded_cell)
# and as the Turbo Frame response returned after an inline edit is saved.
# The frame ID matches so Turbo can swap the content after form submission.
#
# The edit form is a native HTML form inside the turbo-frame, so Turbo
# intercepts the submission, sends the PATCH request, and swaps the frame
# automatically — no custom JavaScript fetch needed.
#
class Views::Frameworks::Explorer::IllustrationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::MenuItems
  include Views::Frameworks::Explorer::Concerns::DiscussTrigger

  # @param illustration [FrameworkState::RoleIllustration]
  # @param framework_id [String] UUID of the framework (for the PATCH URL)
  # @param pending_edit_count [Integer] number of pending edit suggestions on this illustration
  # @param pending_edit [Hash, nil] latest pending edit descriptor
  #   ({ suggested_value:, suggestion_id:, created_at: }) — when present, the
  #   description renders as an inline diff instead of the plain value.
  # @param mode [Symbol] :view or :edit — gates the pencil affordance
  # @param can_reorder [Boolean] render the ↑/↓ move chevrons (edit-rights
  #   holders, list has >1 item) — the enclosing UL carries the reorder-list
  #   Stimulus controller these buttons dispatch to
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] per-viewer
  #   authority — gates the pending-edit approve/reject kebab (§12). Controller
  #   frame re-renders must re-thread it (Hard-Won Lesson 13/16 class).
  # @param clarification [Hash, nil] `{ count:, suggestion_id: }` for open
  #   discussions on this example — renders the clickable comment glyph
  # @param discuss_context_label [String, nil] where this example sits, shown in
  #   the "Discuss…" modal ("Strategic Thinking · L4 · Software Engineer
  #   example"). The frame knows only the illustration, so the caller supplies
  #   it; absent, the modal simply omits the context line.
  # @param error [String, nil] a rejected inline save — the shared editor
  #   re-opens here with the attempted value (see CapabilityNameFrame)
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(illustration:, framework_id:, pending_edit_count: 0, pending_edit: nil, mode: :view,
                 can_reorder: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 discuss_context_label: nil, clarification: nil,
                 error: nil, attempted_value: nil)
    @illustration = illustration
    @framework_id = framework_id
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @mode = mode
    @can_reorder = can_reorder
    @approval_authority = approval_authority
    @discuss_context_label = discuss_context_label
    @clarification = clarification || { count: 0, suggestion_id: nil }
    @error = error
    @attempted_value = attempted_value
  end

  def view_template
    turbo_frame_tag(
      "illustration-#{@illustration.illustration_id}",
      data: { reorder_item_id: @illustration.illustration_id }
    ) do
      attrs = {
        class: "relative text-xs text-gray-600 dark:text-gray-400"
      }
      attrs[:data] = hover_cluster_data("ill").merge(editor_data) if @mode == :edit

      li(**attrs) do
        error_line if @mode == :edit
        display_mode
      end
    end
  end

  private

  # Data the shared field editor clones its form from. Illustration text is
  # tier-1 content, so Save vs Propose follows role_illustration authority.
  def editor_data
    field_editor_data(
      action: framework_illustration_path(
        framework_id: @framework_id, id: @illustration.illustration_id
      ),
      field: "illustration[description]",
      value: @error ? @attempted_value.to_s : inline_editor_value(@illustration.description, @pending_edit),
      label: "Illustration text",
      entity: "role_illustration",
      rows: 3,
      form_class: "pl-2",
      error: @error
    )
  end

  def error_line
    return if @error.blank?

    div(class: "pl-2") { render_field_editor_error(@error) }
  end

  def display_mode
    div(
      class: "flex items-start gap-1.5 pl-2",
      data: { editor_display: true }
    ) do
      render_illustration_marker("bg-gray-300 dark:bg-gray-600")
      if @pending_edit
        span(class: "flex-1") do
          render_inline_diff(original: @illustration.description, pending_edit: @pending_edit)
        end
      else
        decoration = suggestion_text_classes(pending_edit_count: @pending_edit_count)
        span(class: "flex-1 #{decoration}".strip) { @illustration.description }
      end
      if @mode == :edit
        # Open discussion on this example — content glyph, never the
        # pending-change vocabulary (nothing is proposed).
        render_clarification_glyph(@clarification[:count], suggestion_id: @clarification[:suggestion_id])
        # pencil · kebab — reorder is a kebab item now, the ONE reorder
        # treatment (framework-explorer.md §11).
        render_hover_cluster(
          scope: "ill",
          pencil: { aria_label: "Edit illustration" },
          menu: { label: "Illustration actions", kind: "illustration", **illustration_menu_data }
        )
      end
    end
  end

  # The pending edit is approvable from the grid when the viewer clears the
  # illustration tier — same §12 machinery as the row and cell kebabs.
  def approvable_pending_edit?
    @pending_edit.present? &&
      @pending_edit[:suggestion_id].present? &&
      @approval_authority.can_approve?("role_illustration")
  end

  # The illustration's ⋮ menu, as data: Approve / Reject for an approvable
  # pending edit, "Edit example…" (the kebab's stand-in for the pencil on a
  # touch device), Discuss…, Move up / Move down, and Archive… (any edit-mode
  # viewer — the Operation decides direct vs suggestion). The illustration's own
  # id comes from the enclosing `[data-reorder-item-id]` frame; the paths from
  # the explorer root.
  def illustration_menu_data
    data = { context: @discuss_context_label }
    data.merge!(approval_menu_data(@pending_edit)) if approvable_pending_edit?
    data[:move] = "1" if @can_reorder
    data
  end
end
