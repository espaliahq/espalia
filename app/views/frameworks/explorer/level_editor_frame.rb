# frozen_string_literal: true

# The "Edit levels" editor — body of the shared `level-editor` modal, rendered
# inside the `level-editor` Turbo Frame so row saves / entry moves / adds
# re-render it in place (the modal stays open). Lists the role's levels sorted
# by ordinal — each row with title + code inputs and a Save, plus an
# entry-flag column (radio-with-clear: "Set as entry" moves the badge, the
# controller clears the previous holder) — and an add-level row at the foot.
#
# Graph-sourced, so draft-added levels are listed and editable (Lesson 17),
# wearing the wiggle (the universal "differs from published" signal). This is
# the surface reordering will land into.
class Views::Frameworks::Explorer::LevelEditorFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param framework_id [String]
  # @param role [Frameworks::ExplorerGraph::Role] graph node (incl. draft levels)
  # @param error [String, nil] message to surface from a failed action
  def initialize(framework_id:, role:, error: nil)
    @framework_id = framework_id
    @role = role
    @error = error
  end

  def view_template
    turbo_frame_tag("level-editor") do
      div(class: "space-y-4") do
        error_banner if @error.present?
        intro
        level_rows
        add_level_row
      end
    end
  end

  private

  def levels
    @levels ||= @role.levels.sort_by(&:ordinal)
  end

  def next_ordinal
    (levels.map(&:ordinal).max || 0) + 1
  end

  def error_banner
    div(class: "rounded-md bg-red-50 dark:bg-red-900/20 border border-red-200 " \
               "dark:border-red-800 px-3 py-2 text-sm text-red-700 dark:text-red-300") { @error }
  end

  def intro
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      plain "Levels of "
      span(class: "font-semibold text-gray-900 dark:text-white") { @role.name }
      plain ". New levels join the draft and publish with the next version."
    end
  end

  def level_rows
    if levels.empty?
      p(class: "text-sm text-gray-500 dark:text-gray-400 italic") { "No levels yet." }
      return
    end

    ul(class: "divide-y divide-gray-100 dark:divide-gray-800 rounded-md border " \
              "border-gray-200 dark:border-gray-700") do
      levels.each { |level| level_row(level) }
    end
  end

  def level_row(level)
    li(class: "flex flex-wrap items-center gap-3 px-3 py-2") do
      # A draft-added level wears the wiggle on its ordinal chip — it differs
      # from the published framework until the next version.
      span(
        class: "shrink-0 w-9 text-center text-xs font-semibold text-gray-500 dark:text-gray-400 " \
               "#{suggestion_text_classes(added_in_draft: level.added_in_draft)}".strip,
        title: draft_change_title(level.added_in_draft)
      ) { "L#{level.ordinal}" }
      row_form(level)
      entry_control(level)
    end
  end

  # Title + code + Save — PATCHes the level, re-rendering the frame.
  def row_form(level)
    form(
      action: framework_level_path(@framework_id, level.level_id),
      method: "post", class: "min-w-0 flex-1 flex flex-wrap items-center gap-2"
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(
        type: "text", name: "level[title]", value: level.title, required: true,
        aria: { label: "Title for level #{level.ordinal}" },
        # min-w-32 (not 0) so the title wraps the row on narrow viewports
        # instead of collapsing to an unusable sliver.
        class: "min-w-32 flex-1 #{field_classes}"
      )
      # Code + Save stay one unbreakable cluster — when the row is tight, the
      # title wraps to its own line rather than Save orphaning below the code.
      div(class: "flex items-center gap-2 shrink-0") do
        input(
          type: "text", name: "level[code]", value: level.code, required: true,
          aria: { label: "Code for level #{level.ordinal}" },
          class: "w-20 #{field_classes}"
        )
        button(
          type: "submit",
          class: "rounded px-2 py-1 text-[11px] font-medium text-primary-ink hover:bg-primary/10 transition-colors"
        ) { "Save" }
      end
    end
  end

  # Radio-with-clear entry flag: the current holder shows a badge; every other
  # row offers "Set as entry", a one-click PATCH — the controller clears the
  # previous holder so at most one level per role carries the flag.
  def entry_control(level)
    if level.is_entry
      span(
        class: "shrink-0 inline-flex items-center rounded-full bg-primary/10 text-primary-ink " \
               "px-2 py-0.5 text-[11px] font-semibold"
      ) { "Entry" }
    else
      form(action: framework_level_path(@framework_id, level.level_id), method: "post", class: "shrink-0") do
        input(type: "hidden", name: "_method", value: "patch")
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "level[is_entry]", value: "1")
        button(
          type: "submit",
          class: "rounded px-2 py-1 text-[11px] font-medium text-gray-500 dark:text-gray-400 " \
                 "hover:text-primary-ink hover:bg-primary/10 transition-colors"
        ) { "Set as entry" }
      end
    end
  end

  def add_level_row
    form(
      action: framework_levels_path(@framework_id),
      method: "post", class: "flex flex-wrap items-end gap-2 pt-1"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "level[role_id]", value: @role.role_id)
      div do
        label(for: "level-editor-add-ordinal", class: add_label_classes) { "Level" }
        input(
          type: "number", id: "level-editor-add-ordinal", name: "level[ordinal]",
          value: next_ordinal, min: "1", required: true, class: "w-16 #{field_classes}"
        )
      end
      div(class: "min-w-0 flex-1") do
        label(for: "level-editor-add-title", class: add_label_classes) { "Title" }
        input(
          type: "text", id: "level-editor-add-title", name: "level[title]", required: true,
          placeholder: "e.g. Senior #{@role.name}", class: "w-full #{field_classes}"
        )
      end
      div do
        label(for: "level-editor-add-code", class: add_label_classes) { "Code" }
        input(
          type: "text", id: "level-editor-add-code", name: "level[code]", required: true,
          placeholder: "e.g. #{@role.code}#{next_ordinal}", class: "w-20 #{field_classes}"
        )
      end
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-3 py-1.5 text-sm font-semibold " \
               "text-white hover:bg-primary/90 transition-colors shrink-0"
      ) { "Add level" }
    end
  end

  def add_label_classes = "block text-[11px] font-medium text-gray-500 dark:text-gray-400 mb-1"

  def field_classes
    "rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 " \
      "px-2 py-1 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
