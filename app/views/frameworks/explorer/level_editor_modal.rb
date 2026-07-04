# frozen_string_literal: true

# Shared "Edit levels" modal for the Framework Explorer (edit mode). One
# instance per page; each role row's kebab "Edit levels…" item opens it,
# passing the role id via the trigger dataset (read by the `level-editor-form`
# Stimulus controller, which points the `level-editor` Turbo Frame at
# {Frameworks::LevelsController#index} for that role). Row saves, entry moves,
# and adds re-render the frame in place; the controller also asks the matrix to
# re-fetch on each successful save, since level titles/codes render in the
# matrix header.
class Views::Frameworks::Explorer::LevelEditorModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "level-editor-modal", title: "Edit levels", size: :lg, standalone: false
    ) do |m|
      m.body { body }
    end
  end

  private

  def body
    div(
      data: {
        controller: "level-editor-form",
        level_editor_form_levels_url_value: framework_levels_path(@framework_id),
        action: "turbo:submit-end->level-editor-form#submitted"
      }
    ) do
      turbo_frame_tag("level-editor", data: { level_editor_form_target: "frame" }) do
        p(class: "text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
      end
    end
  end
end
