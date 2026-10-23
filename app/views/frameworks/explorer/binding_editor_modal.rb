# frozen_string_literal: true

# Shared "Edit roles" modal for the Framework Explorer (edit mode). One instance
# per page; each capability's row-actions kebab "Edit roles…" item opens it,
# passing the capability id/name via the trigger dataset (read by the
# `binding-editor-form` Stimulus controller, which points the `binding-editor`
# Turbo Frame at {Frameworks::CapabilityBindingsController#index} for that
# capability). All add / update / remove actions re-render the frame in place.
class Views::Frameworks::Explorer::BindingEditorModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "binding-editor-modal", title: "Edit roles", standalone: false
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
        controller: "binding-editor-form frame-error",
        binding_editor_form_bindings_url_value: framework_capability_bindings_path(@framework_id)
      }
    ) do
      turbo_frame_tag("binding-editor",
                      data: { binding_editor_form_target: "frame", frame_error_target: "frame" }) do
        p(class: "text-sm text-muted") { "Loading…" }
      end
      render Components::Shared::FrameLoadError.new(
        id: "binding-editor-error", subject: "the roles editor", closeable: true, classes: "space-y-3"
      )
    end
  end
end
