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

  # @param illustration [FrameworkState::RoleIllustration]
  # @param framework_id [String] UUID of the framework (for the PATCH URL)
  # @param pending_edit_count [Integer] number of pending edit suggestions on this illustration
  # @param mode [Symbol] :view or :edit — gates the pencil affordance
  def initialize(illustration:, framework_id:, pending_edit_count: 0, mode: :view)
    @illustration = illustration
    @framework_id = framework_id
    @pending_edit_count = pending_edit_count
    @mode = mode
  end

  def view_template
    turbo_frame_tag("illustration-#{@illustration.illustration_id}") do
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
      class: "flex items-start gap-1 pl-2",
      data: { inline_editor_target: "display" }
    ) do
      decoration = suggestion_text_classes(pending_edit_count: @pending_edit_count)
      span(class: "flex-1 #{decoration}".strip) { @illustration.description }
      edit_button if @mode == :edit
    end
  end

  def edit_button
    button(
      type: "button",
      class: "opacity-0 group-hover/ill:opacity-100 transition-opacity " \
             "text-gray-400 hover:text-primary shrink-0 mt-0.5",
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
      ) { @illustration.description }

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
