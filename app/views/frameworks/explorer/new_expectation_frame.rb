# frozen_string_literal: true

# "+ Add expectation" affordance for an empty-but-applicable matrix cell (edit
# mode). The shared dashed-ghost add treatment (HoverCluster#render_add_affordance),
# always visible, opening the shared field editor and POSTing to
# {Frameworks::ExpectationsController#create}.
#
# The submit answers a Turbo Stream that replaces just this cell (with the
# authored expectation, or with its pending ghost) plus the toast — so
# authoring never costs the page. `tree-scope-fields` rides along on the form so
# the re-rendered cell is built against the same role/track/search scope the
# grid around it was.
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
    div(data: editor_data) do
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
      form_controller: "tree-scope-fields",
      placeholder: "What does good look like at this level…",
      extra: {
        "behavioural_expectation[capability_id]" => @capability_id,
        "behavioural_expectation[level_ordinal]" => @level_ordinal
      }
    )
  end

  def add_button
    render_add_affordance(
      "Add expectation", editor_display: true, action: "field-editor#open"
    )
  end
end
