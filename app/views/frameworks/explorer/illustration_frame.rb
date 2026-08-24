# frozen_string_literal: true

# Renders a single role illustration inside its Turbo Frame.
#
# Used both in the initial matrix render (inside MatrixRow#expanded_cell)
# and as the Turbo Frame response returned after an inline edit is saved.
# The frame ID matches so Turbo can swap the content after form submission.
#
# The edit form is a native HTML form inside the turbo-frame, so Turbo
# intercepts the submission, sends the PATCH request, and swaps the frame
# automatically — no custom JavaScript fetch needed.
#
class Views::Frameworks::Explorer::IllustrationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::ApprovalKebabItems

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
  def initialize(illustration:, framework_id:, pending_edit_count: 0, pending_edit: nil, mode: :view,
                 can_reorder: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @illustration = illustration
    @framework_id = framework_id
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @mode = mode
    @can_reorder = can_reorder
    @approval_authority = approval_authority
  end

  def view_template
    turbo_frame_tag(
      "illustration-#{@illustration.illustration_id}",
      data: { reorder_item_id: @illustration.illustration_id }
    ) do
      attrs = {
        class: "group/ill relative text-xs text-gray-600 dark:text-gray-400"
      }
      attrs[:data] = { controller: "inline-editor" } if @mode == :edit

      li(**attrs) do
        display_mode
        edit_mode if @mode == :edit
      end
    end
  end

  private

  def display_mode
    div(
      class: "flex items-start gap-1.5 pl-2",
      data: { inline_editor_target: "display" }
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
        reorder_buttons if @can_reorder
        edit_button
        # Kebab last — always the right-most control (phlex-views.md).
        actions_kebab
      end
    end
  end

  # The pending edit is approvable from the grid when the viewer clears the
  # illustration tier — same §12 kebab machinery as the row and cell kebabs.
  def approvable_pending_edit?
    @pending_edit.present? &&
      @pending_edit[:suggestion_id].present? &&
      @approval_authority.can_approve?("role_illustration")
  end

  # The illustration's ⋮ menu: Approve / Reject for an approvable pending edit,
  # plus Archive… (any edit-mode viewer — the Operation decides direct vs
  # suggestion). Archive lives here rather than as a standalone icon so the
  # hover cluster stays pencil-then-kebab.
  def actions_kebab
    render Components::Kit::Dropdown.new(align: :left) do |dd|
      # focus-within, not focus-visible: focus lands on the dropdown's
      # <button>, so focus-visible on this inner span could never match.
      kebab_trigger(dd, label: "Illustration actions",
        reveal_classes: "opacity-0 group-hover/ill:opacity-100 " \
                        "group-focus-within/ill:opacity-100")
      dd.menu do
        if approvable_pending_edit?
          render_approval_kebab_items(
            framework_id: @framework_id,
            suggestion_id: @pending_edit[:suggestion_id],
            change_label: "illustration change",
            entity_label: "illustration",
            preview: @pending_edit[:suggested_value].to_s
          )
        end
        archive_menu_item
      end
    end
  end

  # ↑/↓ move-within-list chevrons, hover-revealed like the pencil. The action
  # handlers live on the enclosing UL's reorder-list controller, which POSTs
  # the neighbour-relative move and repositions this frame's node on success.
  def reorder_buttons
    reorder_button("Move illustration up", "reorder-list#moveUp", "M4.5 15.75l7.5-7.5 7.5 7.5")
    reorder_button("Move illustration down", "reorder-list#moveDown", "M19.5 8.25l-7.5 7.5-7.5-7.5")
  end

  def reorder_button(label, action, chevron_path)
    button(
      type: "button",
      class: "opacity-0 group-hover/ill:opacity-100 " \
             "group-focus-within/ill:opacity-100 focus-visible:opacity-100 " \
             "transition-opacity text-gray-400 hover:text-primary shrink-0 mt-0.5",
      data: { action: action },
      aria_label: label
    ) do
      svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2") do |s|
        s.path(stroke_linecap: "round", stroke_linejoin: "round", d: chevron_path)
      end
    end
  end

  # Archive (remove) the illustration — a ⋮ menu item, not a standalone icon.
  # The IllustrationArchivesController + ArchiveIllustration operation decide,
  # from the edit/suggest toggle + the viewer's authority, whether it removes
  # directly or proposes a suggestion. A small inline form (Turbo handles CSRF +
  # the redirect, same as the edit form); turbo-confirm guards the click.
  def archive_menu_item
    form(
      method: "post",
      action: framework_illustration_archives_path(framework_id: @framework_id),
      # role=none: a <form> interrupting the menuitem's menu ancestry breaks
      # the ARIA menu contract (Kit::Dropdown's documented rule).
      # turbo_frame _top: the controller redirects to the full edit page, and
      # this form lives inside the illustration's Turbo Frame — without _top
      # the redirect renders "Content missing" in the expanded row and drops
      # the flash (phlex-views.md, in-frame navigation rule).
      role: "none",
      data: { turbo: "true", turbo_frame: "_top", turbo_confirm: "Archive this illustration?" }
    ) do
      input(type: "hidden", name: "archive[illustration_id]", value: @illustration.illustration_id)
      button(
        type: "submit", role: "menuitem",
        class: kebab_item_classes("text-gray-700 dark:text-gray-200")
      ) { "Archive…" }
    end
  end

  def edit_button
    button(
      type: "button",
      class: "opacity-0 group-hover/ill:opacity-100 " \
             "group-focus-within/ill:opacity-100 focus-visible:opacity-100 " \
             "transition-opacity text-gray-400 hover:text-primary shrink-0 mt-0.5",
      data: { action: "inline-editor#startEdit" },
      aria_label: "Edit illustration"
    ) do
      # Pencil icon
      svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2") do |s|
        s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                  "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
      end
    end
  end

  def edit_mode
    form(
      class: "hidden pl-2",
      method: "post",
      action: framework_illustration_path(
        framework_id: @framework_id,
        id: @illustration.illustration_id
      ),
      data: {
        inline_editor_target: "form",
        turbo: "true",
        action: "turbo:submit-end->inline-editor#submitted"
      }
    ) do
      input(type: "hidden", name: "_method", value: "patch")

      textarea(
        class: "w-full text-xs border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
        rows: "3",
        name: "illustration[description]",
        data: { inline_editor_target: "input" }
      ) { (@pending_edit ? @pending_edit[:suggested_value] : @illustration.description).to_s }

      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
        ) { "Save" }
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
