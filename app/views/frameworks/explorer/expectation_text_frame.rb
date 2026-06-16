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
  def initialize(expectation:, framework_id:, mode: :view, pending_edit_count: 0, pending_edit: nil,
                 search_query: nil)
    @expectation = expectation
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @search_query = search_query
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
      p(class: "#{base} #{decoration}".strip) { render_highlighted(@expectation.description, @search_query) }
    end
  end

  def editable
    div(class: "group/ine relative",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-1",
          data: { inline_editor_target: "display" }) do
        plain_text
        render_inline_editor_pencil(aria_label: "Edit expectation text")
      end
      render_inline_editor_form(
        action: framework_expectation_path(framework_id: @framework_id, id: @expectation.expectation_id),
        field_name: "behavioural_expectation[description]",
        current_value: inline_editor_value(@expectation.description, @pending_edit),
        rows: 3
      )
    end
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count)
  end
end
