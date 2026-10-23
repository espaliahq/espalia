# frozen_string_literal: true

# Turbo Frame wrapping a capability category's name + inline edit
# affordance in the sticky matrix category header. Mirrors
# {Views::Frameworks::Explorer::CapabilityNameFrame}.
#
class Views::Frameworks::Explorer::CategoryNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  # @param category [FrameworkState::CapabilityCategory, Frameworks::ExplorerGraph::CapabilityCategory]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  # @param pending_edit [Hash, nil] latest pending edit descriptor
  #   ({ suggested_value:, suggestion_id:, created_at: }) — when present, the
  #   name renders as an inline diff instead of the plain value.
  # @param search_query [String, nil] active text filter — match terms are
  #   highlighted in the name (skipped when a pending-edit diff is shown).
  # @param error [String, nil] a rejected inline save (see CapabilityNameFrame)
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(category:, framework_id:, mode: :view, pending_edit_count: 0, pending_edit: nil,
                 search_query: nil, error: nil, attempted_value: nil)
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
    base = "text-sm font-semibold text-muted"
    if @pending_edit
      span(class: base) do
        # interactive: false — this renders inside the category header's
        # role=button focus target (MatrixCategoryGroup); a nested open-card
        # widget would swallow its accessible name and steal the
        # focus-category click. The pane still reaches this suggestion via
        # the feed entry / row context.
        render_inline_diff(original: @category.name, pending_edit: @pending_edit, interactive: false)
      end
    else
      span(class: "#{base} #{decoration}".strip) { render_highlighted(@category.name, @search_query) }
    end
  end

  def editable
    div(class: "inline-flex flex-col items-start gap-1", data: editor_data) do
      render_field_editor_error(@error)
      div(class: "mx-line", data: { editor_display: true }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit category name", scope: "cat")
      end
    end
  end

  def editor_data
    field_editor_data(
      action: framework_category_path(framework_id: @framework_id, id: @category.category_id),
      field: "capability_category[name]",
      value: @error ? @attempted_value.to_s : inline_editor_value(@category.name, @pending_edit),
      label: "Category name",
      entity: "capability_category",
      rows: 1,
      error: @error
    )
  end

  def decoration
    suggestion_text_classes(pending_edit_count: @pending_edit_count)
  end
end
