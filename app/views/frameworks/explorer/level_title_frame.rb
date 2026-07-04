# frozen_string_literal: true

# Turbo Frame wrapping one role's level title in the matrix header + inline-edit
# affordance. Rendered in-place (by {Views::Frameworks::Explorer::MatrixHeader}'s
# full-title badges, edit mode only) and as the PATCH response from
# {Frameworks::LevelsController#update}.
#
# A merged level column can carry several roles' levels at the same ordinal, so
# each per-role title is its own frame keyed by `level_id` — editing one never
# touches the others. Only shown when the header renders full titles (≤ 3 roles
# selected); the compact-code view stays read-only (titles are hidden there).
#
# Org-structure renames are direct (not the suggested-edit path) — no
# pending-suggestion decoration. A **draft-added** level's title does wear the
# wiggle (the universal differs-from-published signal), same as its ordinal
# chip in the levels editor. (Level code edits live in the levels editor.)
#
class Views::Frameworks::Explorer::LevelTitleFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param level_id [String]
  # @param title [String]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param added_in_draft [Boolean] wiggle the title (deferred until publish)
  def initialize(level_id:, title:, framework_id:, mode: :view, added_in_draft: false)
    @level_id = level_id
    @title = title
    @framework_id = framework_id
    @mode = mode
    @added_in_draft = added_in_draft
  end

  def view_template
    turbo_frame_tag("level-title-#{@level_id}", class: "flex w-full justify-center") do
      if @mode == :edit
        editable
      else
        plain_title
      end
    end
  end

  private

  def plain_title
    span(
      class: "text-xs text-gray-600 dark:text-gray-300 " \
             "#{suggestion_text_classes(added_in_draft: @added_in_draft)}".strip,
      title: draft_change_title(@added_in_draft)
    ) { @title }
  end

  def editable
    div(class: "group/ine inline-flex items-start gap-1", data: { controller: "inline-editor" }) do
      # `flex`, NOT `inline-flex`: the inline editor hides this target by
      # adding `hidden`, which ties on specificity with display utilities and
      # loses to `inline-flex` in the bundle's order (it beats `flex`) — the
      # editor then renders BESIDE the still-visible title. See
      # assessments.md Hard-Won Lesson 17.
      div(class: "flex items-start gap-1", data: { inline_editor_target: "display" }) do
        plain_title
        render_inline_editor_pencil(aria_label: "Edit level title")
      end
      # Compact width + single row so the editor stays in place within the
      # narrow, centred level-title header cell (min-w-[180px]) instead of
      # ballooning it with the default sentence-width form.
      render_inline_editor_form(
        action: framework_level_path(framework_id: @framework_id, id: @level_id),
        field_name: "level[title]",
        current_value: @title,
        rows: 1,
        width_classes: "w-36"
      )
    end
  end
end
