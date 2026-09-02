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

  # `frame-error` gives a failed frame GET a voice: without it an
  # un-handled `turbo:frame-missing` renders Turbo's own "Content missing"
  # inside the multi-megabyte edit-mode explorer, with no retry (#365).
  def body
    div(
      data: {
        controller: "level-editor-form frame-error",
        level_editor_form_levels_url_value: framework_levels_path(@framework_id),
        action: "turbo:submit-end->level-editor-form#submitted " \
                "turbo:before-fetch-request->frame-error#requestStarted " \
                "turbo:fetch-request-error->frame-error#loadFailed " \
                "turbo:frame-missing->frame-error#loadFailed " \
                "turbo:before-fetch-response->frame-error#responseReceived " \
                "turbo:frame-load->frame-error#loadSucceeded"
      }
    ) do
      turbo_frame_tag("level-editor",
                      data: { level_editor_form_target: "frame", frame_error_target: "frame" }) do
        p(class: "text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
      end
      render Components::Kit::FrameLoadError.new(
        id: "level-editor-error", closeable: true, classes: "space-y-3",
        message: "Couldn't load the levels editor. Try again — if it keeps failing, close this and reload the page."
      )
    end
  end
end
