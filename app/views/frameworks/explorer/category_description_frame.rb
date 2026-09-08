# frozen_string_literal: true

# Turbo Frame wrapping a capability category's description + inline edit
# affordance in the sticky matrix category header. Rendered in-place by
# {Views::Frameworks::Explorer::MatrixCategoryGroup} and as the PATCH response
# from {Frameworks::CategoriesController#update} when the description field is
# edited. Mirrors {Views::Frameworks::Explorer::CapabilityDescriptionFrame}.
#
# Display mode shows the description (with pending-edit decoration). In :edit a
# hover-revealed pencil + inline form are added; when the description is blank an
# "Add a description…" placeholder gives a target to add one.
class Views::Frameworks::Explorer::CategoryDescriptionFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  TEXT_CLASSES = "text-xs text-gray-500 dark:text-gray-400"

  # @param category [FrameworkState::CapabilityCategory, Frameworks::ExplorerGraph::CapabilityCategory]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  # @param pending_edit [Hash, nil] latest pending edit descriptor (renders as a diff)
  # @param search_query [String, nil]
  # @param error [String, nil] a rejected inline save (see CapabilityNameFrame)
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(category:, framework_id:, mode: :view, pending_edit_count: 0,
                 pending_edit: nil, search_query: nil, error: nil, attempted_value: nil)
    @category = category
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @search_query = search_query
    @error = error
    @attempted_value = attempted_value
  end

  def view_template
    turbo_frame_tag("category-description-#{@category.category_id}") do
      @mode == :edit ? editable : plain_description
    end
  end

  private

  def plain_description
    return if @category.description.blank?

    p(class: TEXT_CLASSES) { decorated_description }
  end

  def decorated_description
    if @pending_edit
      render_inline_diff(original: @category.description.to_s, pending_edit: @pending_edit)
    else
      render_highlighted(@category.description.to_s, @search_query)
    end
  end

  def editable
    div(class: "group/ine flex flex-col items-start gap-1 #{TEXT_CLASSES}", data: editor_data) do
      render_field_editor_error(@error)
      div(class: "flex items-start gap-1", data: { editor_display: true }) do
        if @pending_edit
          # A pending edit renders as the inline diff (its own decoration);
          # don't also apply the wavy-underline class.
          span { render_inline_diff(original: @category.description.to_s, pending_edit: @pending_edit) }
        elsif @category.description.present?
          span(class: suggestion_text_classes(pending_edit_count: @pending_edit_count)) do
            render_highlighted(@category.description.to_s, @search_query)
          end
        else
          span(class: "italic text-gray-400 dark:text-gray-500") { "Add a description…" }
        end
        render_inline_editor_pencil(aria_label: "Edit category description")
      end
    end
  end

  def editor_data
    field_editor_data(
      action: framework_category_path(framework_id: @framework_id, id: @category.category_id),
      field: "capability_category[description]",
      value: @error ? @attempted_value.to_s : inline_editor_value(@category.description, @pending_edit),
      label: "Category description",
      entity: "capability_category",
      rows: 2,
      error: @error
    )
  end
end
