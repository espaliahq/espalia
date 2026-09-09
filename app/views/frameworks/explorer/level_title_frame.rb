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
  include Views::Frameworks::Explorer::Concerns::HoverCluster
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
    # Deliberately shrink-to-fit: the shared editor pins its width to the host's
    # own, and a `w-full` host here sits in a flex row beside the role-code
    # badges, so the pinned px width would be ADDED to the row's intrinsic width
    # and widen the level column by ~108px (Lesson 27). A short level title in a
    # title-width box is the accepted trade.
    div(class: "inline-flex flex-col items-start gap-1", data: hover_cluster_data("hdr").merge(editor_data)) do
      div(class: "mx-line", data: { editor_display: true }) do
        plain_title
        render_inline_editor_pencil(aria_label: "Edit level title", scope: "hdr", collapses: false)
      end
    end
  end

  # Direct edit — no approval tier, so the editor always says "Save". A single
  # row keeps the editor in place within the narrow, centred header cell.
  def editor_data
    field_editor_data(
      action: framework_level_path(framework_id: @framework_id, id: @level_id),
      field: "level[title]",
      value: @title.to_s,
      label: "Level title",
      outcome: "apply",
      rows: 1
    )
  end
end
