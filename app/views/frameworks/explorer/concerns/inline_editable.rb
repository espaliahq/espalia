# frozen_string_literal: true

# Shared Phlex rendering for the explorer's inline-editable text fields.
#
# There is exactly ONE inline-edit form on the page — the inert
# {Views::Frameworks::Explorer::FieldEditorTemplate} on the explorer root,
# cloned into place by `field_editor_controller.js`. A frame therefore renders
# **display markup plus data**: a host element carrying `data-editor-*`, an
# inner `[data-editor-display]`, and a pencil that dispatches
# `field-editor#open`.
#
# Usage (inside a view component that wraps the display text in a
# turbo_frame_tag):
#
#   div(class: "inline-flex items-start gap-1",
#       data: field_editor_data(
#         action: framework_capability_path(...), field: "capability[name]",
#         value: inline_editor_value(@name, @pending_edit), label: "Capability name",
#         entity: "capability", rows: 2, error: @error
#       )) do
#     div(data: { editor_display: true }) do
#       plain @name
#       render_inline_editor_pencil(aria_label: "Edit capability name", scope: "row")
#     end
#     render_field_editor_error(@error)
#   end
#
module Views::Frameworks::Explorer::Concerns::InlineEditable
  # The inline-edit pencil controls are hover-cluster members, so every host needs the
  # cluster's data helpers — pulled in here rather than repeated at ~15 call
  # sites where forgetting one is a NoMethodError at render time.
  def self.included(base)
    super
    base.include(Views::Frameworks::Explorer::Concerns::HoverCluster)
  end

  # Small pencil icon button that opens the shared editor. It is the FIRST
  # control of its entity's hover cluster (pencil · discuss · kebab) and reveals
  # with the rest of it — see {HoverCluster}. On a coarse pointer it is hidden
  # and the entity's kebab carries an "Edit…" item instead.
  #
  # @param aria_label [String]
  # @param scope [String] hover-cluster scope ("row", "cell", "ill", "cat")
  def render_inline_editor_pencil(aria_label:, scope:)
    button(
      type: "button",
      class: "explorer-cluster-btn",
      data: cluster_control_data(scope).merge(action: "field-editor#open"),
      aria_label: aria_label
    ) do
      render_inline_editor_pencil_icon
    end
  end

  # The pencil glyph on its own, for hosts with their own button chrome
  # (the illustration hover cluster).
  def render_inline_editor_pencil_icon
    icon("pencil", class: "w-3 h-3")
  end

  # The value to pre-fill the inline editor with. When a pending suggested edit
  # exists on the field, seed the box with its *proposed* value so the user
  # refines the proposal (matching the inline diff already shown) rather than
  # starting over from the persisted value.
  #
  # @param current_value [Object] the persisted value
  # @param pending_edit [Hash, nil] latest pending edit descriptor ({ suggested_value: })
  # @return [String]
  def inline_editor_value(current_value, pending_edit)
    (pending_edit ? pending_edit[:suggested_value] : current_value).to_s
  end

  # The `data-editor-*` contract the shared editor reads. See
  # `field_editor_controller.js` for the full attribute list.
  #
  # @param action [String] POST/PATCH URL
  # @param field [String] name= for the textarea ("capability[name]")
  # @param value [String] value to seed the editor with
  # @param label [String] accessible name for the textarea
  # @param rows [Integer] initial textarea rows
  # @param entity [String, nil] suggestion entity type — the client derives
  #   Save vs Propose from the viewer's server-computed authority for its tier
  #   plus the Editing/Suggesting mode
  # @param outcome [String, nil] "apply" / "propose" — a FIXED outcome that
  #   overrides `entity` (org-structure renames always apply; an amend of a
  #   pending suggestion always proposes)
  # @param method [String] "patch" (default) or "post"
  # @param submit_label [String, nil] overrides the derived Save/Propose label
  # @param turbo_frame [String, nil] data-turbo-frame for the form
  # @param form_class [String, nil] extra classes for the form element
  # @param form_controller [String, nil] extra Stimulus controller for the form
  # @param extra [Hash] hidden inputs to add to the form
  # @param placeholder [String, nil]
  # @param error [String, nil] a save error — the editor re-opens on this host
  #   automatically, seeded with `value` (the attempted text), so nothing typed
  #   is lost
  # @return [Hash] data attributes for the host element
  def field_editor_data(action:, field:, value:, label:, rows: 3, entity: nil, outcome: nil,
                        method: "patch", submit_label: nil, turbo_frame: nil,
                        form_class: nil, form_controller: nil, extra: {}, placeholder: nil,
                        error: nil)
    {
      editor_action: action,
      editor_field: field,
      editor_value: value.to_s,
      editor_label: label,
      editor_rows: rows.to_s,
      editor_method: method,
      editor_entity: entity,
      editor_outcome: outcome,
      editor_submit_label: submit_label,
      editor_turbo_frame: turbo_frame,
      editor_form_class: form_class,
      editor_form_controller: form_controller,
      editor_placeholder: placeholder,
      editor_extra: (extra.presence && extra.to_json),
      editor_error: error.presence
    }.compact
  end

  # The inline "couldn't save" line a rejected save renders in the cell. The
  # editor re-opens beneath it with the attempted text, so this is the only
  # copy of the message on screen.
  #
  # @param error [String, nil]
  def render_field_editor_error(error)
    return if error.blank?

    # data-editor-error-line: the editor clears this (and the host's
    # data-editor-error) when the user cancels, so a failed-then-abandoned edit
    # doesn't leave a permanent-looking alert in the grid.
    p(class: "text-[11px] text-red-700 dark:text-red-400", role: "alert",
      data: { editor_error_line: true }) do
      "Couldn’t save: #{error}"
    end
  end
end
