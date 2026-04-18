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

  # @param expectation [FrameworkState::BehaviouralExpectation, Frameworks::ExplorerGraph::BehaviouralExpectation]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  def initialize(expectation:, framework_id:, mode: :view, pending_edit_count: 0)
    @expectation = expectation
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
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
    p(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-3 #{decoration}".strip) do
      @expectation.description
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
        current_value: @expectation.description,
        rows: 3
      )
    end
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count)
  end
end
