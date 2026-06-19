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

  def body
    div(
      data: {
        controller: "binding-editor-form",
        binding_editor_form_bindings_url_value: framework_capability_bindings_path(@framework_id)
      }
    ) do
      turbo_frame_tag("binding-editor", data: { binding_editor_form_target: "frame" }) do
        p(class: "text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
      end
    end
  end
end
