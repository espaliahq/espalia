# frozen_string_literal: true

# Renders the "+ Add illustration" affordance inside a Turbo Frame.
#
# After a successful POST the controller returns a Turbo Stream that:
# 1. Appends the new IllustrationFrame to `ul#illustrations-{eid}-{rid}`
# 2. Replaces this frame with a fresh copy (button visible again)
#
# The form itself is NOT pre-rendered — the shared field editor clones it from
# the explorer root's template when the button is clicked.
#
class Views::Frameworks::Explorer::NewIllustrationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param expectation_id [String] UUID of the parent expectation
  # @param role_id [String] UUID of the role this illustration will belong to
  # @param framework_id [String] UUID of the framework (for the POST URL)
  def initialize(expectation_id:, role_id:, framework_id:)
    @expectation_id = expectation_id
    @role_id = role_id
    @framework_id = framework_id
  end

  def view_template
    turbo_frame_tag("new-illustration-#{@expectation_id}-#{@role_id}") do
      div(class: "group/new-ill pl-2 mt-1", data: editor_data) do
        add_button
      end
    end
  end

  private

  def editor_data
    field_editor_data(
      action: framework_illustrations_path(framework_id: @framework_id),
      field: "illustration[description]",
      value: "",
      label: "New illustration",
      entity: "role_illustration",
      method: "post",
      rows: 3,
      submit_label: "Add",
      placeholder: "Describe how this behaviour shows up in this role…",
      extra: {
        "illustration[expectation_id]" => @expectation_id,
        "illustration[role_id]" => @role_id
      }
    )
  end

  def add_button
    button(
      type: "button",
      class: "text-xs text-gray-400 hover:text-primary flex items-center gap-1 py-0.5",
      data: { editor_display: true, action: "field-editor#open" }
    ) do
      svg(
        class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
        stroke: "currentColor", stroke_width: "2"
      ) do |s|
        s.path(d: "M12 4v16m8-8H4")
      end
      plain "Add illustration"
    end
  end
end
