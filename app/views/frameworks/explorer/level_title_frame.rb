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
# pending-suggestion decoration. (Level code edits are exposed via the
# Operation/MCP; no inline UI field yet.)
#
class Views::Frameworks::Explorer::LevelTitleFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param level_id [String]
  # @param title [String]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  def initialize(level_id:, title:, framework_id:, mode: :view)
    @level_id = level_id
    @title = title
    @framework_id = framework_id
    @mode = mode
  end

  def view_template
    turbo_frame_tag("level-title-#{@level_id}", class: "inline-flex justify-center") do
      if @mode == :edit
        editable
      else
        plain_title
      end
    end
  end

  private

  def plain_title
    span(class: "text-xs text-gray-600 dark:text-gray-300") { @title }
  end

  def editable
    div(class: "group/ine inline-flex items-start gap-1", data: { controller: "inline-editor" }) do
      div(class: "inline-flex items-start gap-1", data: { inline_editor_target: "display" }) do
        plain_title
        render_inline_editor_pencil(aria_label: "Edit level title")
      end
      render_inline_editor_form(
        action: framework_level_path(framework_id: @framework_id, id: @level_id),
        field_name: "level[title]",
        current_value: @title
      )
    end
  end
end
