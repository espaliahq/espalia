# frozen_string_literal: true

# @label Frame load error
class Shared::FrameLoadErrorPreview < Lookbook::Preview
  # @param subject text
  # @param closeable toggle
  def playground(subject: "the form", closeable: true)
    revealed(id: "frame-error-playground", subject: subject, closeable: closeable)
  end

  # @!group Revealed

  # In the evidence modal, where Close is the only way out
  def modal
    revealed(id: "evidence-modal-error", subject: "the form", closeable: true)
  end

  # Under a piece of evidence, where its thread failed to load
  def discussion
    revealed(id: "evidence-thread-error", subject: "the discussion", classes: "py-1 space-y-2")
  end

  # In the framework explorer's expanded row, which reloads itself
  def expanded_row
    revealed(id: "expanded-row-error", subject: "the examples for this capability",
             classes: "space-y-2", retry_action: "matrix#retryExpandedRow")
  end

  # @!endgroup

  private

  def revealed(**options)
    render_with_template(
      template: "shared/frame_load_error_preview/revealed",
      locals: { component: Components::Shared::FrameLoadError.new(**options), id: options[:id] }
    )
  end
end
