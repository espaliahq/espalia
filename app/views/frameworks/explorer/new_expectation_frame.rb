# frozen_string_literal: true

# "+ Add expectation" affordance for an empty-but-applicable matrix cell (edit
# mode). Mirrors NewIllustrationFrame: a hover-revealed button that opens the
# shared field editor and POSTs to {Frameworks::ExpectationsController#create}.
#
# The submit is a full Turbo Drive navigation (`data-turbo-frame="_top"`) —
# authoring is shape-changing, so the controller redirects back to the edit page
# with the new cell rendered, matching the other structural adds.
class Views::Frameworks::Explorer::NewExpectationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param capability_id [String] UUID of the capability owning the cell
  # @param level_ordinal [Integer] the empty cell's level ordinal
  # @param framework_id [String] UUID of the framework (for the POST URL)
  def initialize(capability_id:, level_ordinal:, framework_id:)
    @capability_id = capability_id
    @level_ordinal = level_ordinal
    @framework_id = framework_id
  end

  def view_template
    div(class: "group/new-exp", data: editor_data) do
      add_button
    end
  end

  private

  def editor_data
    field_editor_data(
      action: framework_expectations_path(framework_id: @framework_id),
      field: "behavioural_expectation[description]",
      value: "",
      label: "New expectation",
      entity: "behavioural_expectation",
      method: "post",
      rows: 3,
      submit_label: "Add",
      turbo_frame: "_top",
      placeholder: "What does good look like at this level…",
      extra: {
        "behavioural_expectation[capability_id]" => @capability_id,
        "behavioural_expectation[level_ordinal]" => @level_ordinal
      }
    )
  end

  def add_button
    button(
      type: "button",
      class: "w-full text-xs text-gray-400 hover:text-primary flex items-center justify-center gap-1 " \
             "py-1.5 opacity-0 group-hover/new-exp:opacity-100 focus-visible:opacity-100 transition-opacity",
      data: { editor_display: true, action: "field-editor#open" }
    ) do
      icon("plus", class: "w-3 h-3")
      plain "Add expectation"
    end
  end
end
