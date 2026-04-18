# frozen_string_literal: true

# Shared Phlex rendering for the edit affordance on an inline-editable
# text field (capability name, category name, expectation description).
#
# The display side is kept inline per-entity — the markup differs enough
# (sticky column cell, sticky category header, cell paragraph) that a
# shared display template would be awkward. Only the pencil button and
# the edit <form> are extracted.
#
# Usage (inside a view component that wraps the display text in a
# turbo_frame_tag AND adds `data-controller="inline-editor"`):
#
#   span(class: "...", data: { inline_editor_target: "display" }) do
#     plain @name
#     render_inline_editor_pencil(aria_label: "Edit name")
#   end
#   render_inline_editor_form(
#     action: framework_capability_path(framework_id: @framework_id, id: @cap_id),
#     field_name: "capability[name]",
#     current_value: @name
#   )
#
module Views::Frameworks::Explorer::Concerns::InlineEditable
  # Small pencil icon button that triggers inline-editor#startEdit. Visible
  # on hover via the `group-hover/ill` / `group-hover/ine` token defined by
  # the caller on an ancestor element.
  #
  # @param aria_label [String]
  # @param hover_token [String] tailwind group-hover token, e.g. "ine"
  def render_inline_editor_pencil(aria_label:, hover_token: "ine")
    button(
      type: "button",
      class: "opacity-0 group-hover/#{hover_token}:opacity-100 transition-opacity " \
             "text-gray-400 hover:text-primary shrink-0",
      data: { action: "inline-editor#startEdit" },
      aria_label: aria_label
    ) do
      svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2") do |s|
        s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                  "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
      end
    end
  end

  # Renders the edit-mode form. Hidden until `inline-editor#startEdit` reveals
  # it. Turbo handles the PATCH submission and swaps the frame on response.
  #
  # @param action [String] the form POST URL
  # @param field_name [String] the name attribute for the textarea ("capability[name]")
  # @param current_value [String]
  # @param rows [Integer] textarea rows (default 2)
  def render_inline_editor_form(action:, field_name:, current_value:, rows: 2)
    form(
      class: "hidden",
      method: "post",
      action: action,
      data: { inline_editor_target: "form", turbo: "true" }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      textarea(
        class: "w-full text-sm border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
        rows: rows.to_s,
        name: field_name,
        data: { inline_editor_target: "input" }
      ) { current_value.to_s }

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
