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
#   div(class: "group/ine inline-flex items-start gap-1",
#       data: field_editor_data(
#         action: framework_capability_path(...), field: "capability[name]",
#         value: inline_editor_value(@name, @pending_edit), label: "Capability name",
#         entity: "capability", rows: 2, error: @error
#       )) do
#     div(data: { editor_display: true }) do
#       plain @name
#       render_inline_editor_pencil(aria_label: "Edit capability name")
#     end
#     render_field_editor_error(@error)
#   end
#
module Views::Frameworks::Explorer::Concerns::InlineEditable
  # Small pencil icon button that opens the shared editor. Visible on hover via
  # the `group-hover/ine` token — the caller must add `group/ine` to an
  # ancestor element.
  #
  # The class literal is intentionally not built by interpolation because
  # Tailwind's JIT scans source files and only generates CSS for the exact
  # strings it sees. An interpolated `group-hover/#{token}:opacity-100` is
  # invisible to the scanner — the class lands on the element but no
  # matching CSS is produced, so the pencil stays permanently hidden.
  #
  # @param aria_label [String]
  def render_inline_editor_pencil(aria_label:)
    # Visible on hover (desktop pointer) and on keyboard focus so
    # tab-navigating users can reach the edit affordance too.
    button(
      type: "button",
      class: "opacity-0 group-hover/ine:opacity-100 " \
             "group-focus-within/ine:opacity-100 focus-visible:opacity-100 " \
             "transition-opacity text-gray-400 hover:text-primary shrink-0",
      data: { action: "field-editor#open" },
      aria_label: aria_label
    ) do
      render_inline_editor_pencil_icon
    end
  end

  # The pencil glyph on its own, for hosts with their own button chrome
  # (the illustration hover cluster).
  def render_inline_editor_pencil_icon
    svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
        stroke: "currentColor", stroke_width: "2") do |s|
      s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
    end
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
