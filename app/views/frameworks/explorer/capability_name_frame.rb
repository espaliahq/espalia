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
  # @param error [String, nil] a rejected inline save — rendered as an inline
  #   message; the shared editor re-opens here with the attempted value
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(capability:, framework_id:, mode: :view, pending_edit_count: 0, pending_edit: nil,
                 search_query: nil, error: nil, attempted_value: nil)
    @capability = capability
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @search_query = search_query
    @error = error
    @attempted_value = attempted_value
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
      span(class: "#{base} #{decoration}".strip, title: draft_change_title(added_in_draft?)) do
        render_highlighted(@capability.name, @search_query)
      end
    end
  end

  def added_in_draft?
    @capability.respond_to?(:added_in_draft) && @capability.added_in_draft
  end

  def editable
    # flex-col: the shared editor is appended after the display element, and a
    # rejected save renders its message above it. Visually identical to a row
    # while only the display child is present.
    div(class: "inline-flex flex-col items-start gap-1", data: editor_data) do
      render_field_editor_error(@error)
      div(class: "flex items-start gap-1", data: { editor_display: true }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit capability name", scope: "row")
      end
    end
  end

  def editor_data
    field_editor_data(
      action: framework_capability_path(framework_id: @framework_id, id: @capability.capability_id),
      field: "capability[name]",
      value: @error ? @attempted_value.to_s : inline_editor_value(@capability.name, @pending_edit),
      label: "Capability name",
      entity: "capability",
      rows: 2,
      error: @error
    )
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count, added_in_draft: added_in_draft?)
  end
end
