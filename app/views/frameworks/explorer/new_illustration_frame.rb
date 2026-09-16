# frozen_string_literal: true

# Renders the "+ Add example" affordance inside a Turbo Frame.
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
      div(class: "pl-2 mt-1", data: editor_data) do
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
      label: "New example",
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
    render_add_affordance(
      "Add example", editor_display: true, action: "field-editor#open"
    )
  end
end
