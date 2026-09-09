# frozen_string_literal: true

# Turbo Frame wrapping a behavioural expectation's description + inline
# edit affordance inside a matrix cell. Mirrors
# {Views::Frameworks::Explorer::CapabilityNameFrame}, but the field is
# `description` rather than `name`.
#
class Views::Frameworks::Explorer::ExpectationTextFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  # @param expectation [FrameworkState::BehaviouralExpectation, Frameworks::ExplorerGraph::BehaviouralExpectation]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  # @param pending_edit [Hash, nil] latest pending edit descriptor
  #   ({ suggested_value:, suggestion_id:, created_at: }) — when present, the
  #   description renders as an inline diff instead of the plain value.
  # @param search_query [String, nil] active text filter — match terms are
  #   highlighted in the description (skipped when a pending-edit diff is shown).
  # @param error [String, nil] a rejected inline save (see CapabilityNameFrame)
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(expectation:, framework_id:, mode: :view, pending_edit_count: 0, pending_edit: nil,
                 search_query: nil, error: nil, attempted_value: nil)
    @expectation = expectation
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @search_query = search_query
    @error = error
    @attempted_value = attempted_value
  end

  def view_template
    turbo_frame_tag("expectation-text-#{@expectation.expectation_id}") do
      if @mode == :edit
        editable
      else
        plain_text
      end
    end
  end

  private

  def plain_text
    # Full text — no line-clamp. The matrix row grows to accommodate.
    # Truncating expectation text loses critical behavioural nuance, and
    # the cell width plus the viewer's horizontal scroll are already doing
    # the width-budget negotiation.
    base = "text-sm text-gray-700 dark:text-gray-300"
    if @pending_edit
      p(class: base) do
        render_inline_diff(original: @expectation.description, pending_edit: @pending_edit)
      end
    else
      p(class: "#{base} #{decoration}".strip, title: draft_change_title(added_in_draft?)) do
        render_highlighted(@expectation.description, @search_query)
      end
    end
  end

  def added_in_draft?
    @expectation.respond_to?(:added_in_draft) && @expectation.added_in_draft
  end

  def editable
    div(class: "group/ine relative", data: editor_data) do
      render_field_editor_error(@error)
      div(class: "flex items-start gap-1", data: { editor_display: true }) do
        plain_text
        render_inline_editor_pencil(aria_label: "Edit expectation text")
      end
    end
  end

  def editor_data
    field_editor_data(
      action: framework_expectation_path(framework_id: @framework_id, id: @expectation.expectation_id),
      field: "behavioural_expectation[description]",
      value: @error ? @attempted_value.to_s : inline_editor_value(@expectation.description, @pending_edit),
      label: "Expectation text",
      entity: "behavioural_expectation",
      rows: 3,
      error: @error
    )
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count, added_in_draft: added_in_draft?)
  end
end
