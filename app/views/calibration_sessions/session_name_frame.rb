# frozen_string_literal: true

# Turbo Frame wrapping a calibration session's name — the session page's
# `<h1>` — plus, for a viewer who may rename it, the inline-edit pencil.
# Rendered by {Views::CalibrationSessions::ShowView} and as the PATCH response
# from {CalibrationSessions::NamesController#update}, so the name swaps in
# place.
#
# The framework-rename pattern ({Views::Frameworks::Explorer::FrameworkNameFrame}):
# a direct edit through the shared `field-editor`, Enter saves, Esc cancels,
# and a rejected save comes back as this frame at 422 with the message and the
# typed text. The editor host is a `<div>` around the heading because the
# editor appends a `<form>`, which may not sit inside an `<h1>`.
class Views::CalibrationSessions::SessionNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param session [CalibrationSession]
  # @param can_rename [Boolean] CalibrationSessionPolicy#rename? for the viewer
  # @param error [String, nil] a rejected save's message
  # @param attempted_value [String, nil] what the rejected save carried
  def initialize(session:, can_rename: false, error: nil, attempted_value: nil)
    @session = session
    @can_rename = can_rename
    @error = error
    @attempted_value = attempted_value
  end

  # @param session_id [String]
  # @return [String] the frame id, shared with the controller's response
  def self.dom_id_for(session_id)
    "calibration-session-name-#{session_id}"
  end

  def view_template
    turbo_frame_tag(self.class.dom_id_for(@session.id), class: "min-w-0 max-w-full max-sm:w-full") do
      @can_rename ? editable : heading
    end
  end

  private

  def heading
    h1(class: "min-w-0 max-w-full break-words text-2xl font-bold text-default") do
      @session.name
    end
  end

  # The pencil is `standalone`: the header has no kebab for it to collapse
  # into on a coarse pointer, so it stays visible there.
  def editable
    div(class: "flex min-w-0 max-w-full flex-col items-start gap-1",
        data: hover_cluster_data("hdr").merge(editor_data)) do
      div(class: "flex min-w-0 max-w-full items-center gap-1", data: { editor_display: true }) do
        heading
        render_inline_editor_pencil(aria_label: "Rename session", scope: "hdr", collapses: false)
      end
      render_field_editor_error(@error)
    end
  end

  def editor_data
    field_editor_data(
      action: name_calibration_session_path(@session),
      field: "calibration_session[name]",
      value: (@error ? @attempted_value : @session.name).to_s,
      label: "Session name",
      outcome: "apply",
      rows: 1,
      # The heading row wraps, so a floor here pushes nothing off-screen; it
      # keeps a short name from opening a sliver of an editor.
      form_class: "sm:min-w-96",
      error: @error
    )
  end
end
