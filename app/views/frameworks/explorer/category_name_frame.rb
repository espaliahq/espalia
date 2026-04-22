# frozen_string_literal: true

# Turbo Frame wrapping a capability category's name + inline edit
# affordance in the sticky matrix category header. Mirrors
# {Views::Frameworks::Explorer::CapabilityNameFrame}.
#
class Views::Frameworks::Explorer::CategoryNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param category [FrameworkState::CapabilityCategory, Frameworks::ExplorerGraph::CapabilityCategory]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  def initialize(category:, framework_id:, mode: :view, pending_edit_count: 0)
    @category = category
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
  end

  def view_template
    turbo_frame_tag("category-name-#{@category.category_id}") do
      if @mode == :edit
        editable
      else
        plain_name
      end
    end
  end

  private

  def plain_name
    span(class: "text-sm font-semibold text-gray-700 dark:text-gray-300 #{decoration}".strip) do
      @category.name
    end
  end

  def editable
    div(class: "group/ine inline-flex items-start gap-1",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-1",
          data: { inline_editor_target: "display" }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit category name")
      end
      render_inline_editor_form(
        action: framework_category_path(framework_id: @framework_id, id: @category.category_id),
        field_name: "capability_category[name]",
        current_value: @category.name,
        rows: 1
      )
    end
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count)
  end
end
