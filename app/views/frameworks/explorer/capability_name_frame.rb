# frozen_string_literal: true

# Turbo Frame wrapping a capability's name + inline edit affordance in the
# matrix's sticky left column. Rendered both in-place (by
# {Views::Frameworks::Explorer::MatrixRow}) and as the PATCH response from
# {Frameworks::CapabilitiesController#update} so Turbo swaps the frame
# content without losing surrounding matrix state.
#
# Display mode (both :view and :edit) shows the name with suggestion-edit
# decoration (amber wavy underline when a pending edit exists). In :edit,
# a hover-revealed pencil + inline form are added.
#
class Views::Frameworks::Explorer::CapabilityNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  # @param capability [FrameworkState::Capability, Frameworks::ExplorerGraph::Capability]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  # @param pending_edit [Hash, nil] latest pending edit descriptor
  #   ({ suggested_value:, suggestion_id:, created_at: }) — when present, the
  #   name renders as an inline diff instead of the plain value.
  # @param search_query [String, nil] active text filter — match terms are
  #   highlighted in the name (skipped when a pending-edit diff is shown).
  def initialize(capability:, framework_id:, mode: :view, pending_edit_count: 0, pending_edit: nil,
                 search_query: nil)
    @capability = capability
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @search_query = search_query
  end

  def view_template
    turbo_frame_tag("capability-name-#{@capability.capability_id}") do
      if @mode == :edit
        editable
      else
        plain_name
      end
    end
  end

  private

  def plain_name
    base = "text-sm font-medium text-gray-900 dark:text-white"
    if @pending_edit
      span(class: base) do
        render_inline_diff(original: @capability.name, pending_edit: @pending_edit)
      end
    else
      span(class: "#{base} #{decoration}".strip) { render_highlighted(@capability.name, @search_query) }
    end
  end

  def editable
    div(class: "group/ine inline-flex items-start gap-1",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-1",
          data: { inline_editor_target: "display" }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit capability name")
      end
      render_inline_editor_form(
        action: framework_capability_path(framework_id: @framework_id, id: @capability.capability_id),
        field_name: "capability[name]",
        current_value: @capability.name,
        rows: 2
      )
    end
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count)
  end
end
