# frozen_string_literal: true

# Turbo Frame wrapping a capability's description + inline edit affordance in
# the matrix compact row. Rendered in-place by {Views::Frameworks::Explorer::MatrixRow}
# and as the PATCH response from {Frameworks::CapabilitiesController#update} when
# the description field is edited.
#
# Display mode shows the description (with pending-edit decoration). In :edit a
# hover-revealed pencil + inline form are added; when the description is blank an
# "Add a description…" placeholder gives a target to add one.
class Views::Frameworks::Explorer::CapabilityDescriptionFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  TEXT_CLASSES = "text-xs text-gray-600 dark:text-gray-300 mt-0.5"

  # @param capability [FrameworkState::Capability, Frameworks::ExplorerGraph::Capability]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  # @param pending_edit_count [Integer]
  # @param pending_edit [Hash, nil] latest pending edit descriptor (renders as a diff)
  # @param search_query [String, nil]
  def initialize(capability:, framework_id:, mode: :view, pending_edit_count: 0,
                 pending_edit: nil, search_query: nil)
    @capability = capability
    @framework_id = framework_id
    @mode = mode
    @pending_edit_count = pending_edit_count
    @pending_edit = pending_edit
    @search_query = search_query
  end

  def view_template
    turbo_frame_tag("capability-description-#{@capability.capability_id}") do
      @mode == :edit ? editable : plain_description
    end
  end

  private

  def plain_description
    return if @capability.description.blank?

    p(class: TEXT_CLASSES) { decorated_description }
  end

  def decorated_description
    if @pending_edit
      render_inline_diff(original: @capability.description.to_s, pending_edit: @pending_edit)
    else
      render_highlighted(@capability.description.to_s, @search_query)
    end
  end

  def editable
    div(class: "group/ine flex items-start gap-1 #{TEXT_CLASSES}",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-1", data: { inline_editor_target: "display" }) do
        if @pending_edit
          # A pending edit renders as the inline diff (its own decoration);
          # don't also apply the wavy-underline class.
          span { render_inline_diff(original: @capability.description.to_s, pending_edit: @pending_edit) }
        elsif @capability.description.present?
          span(class: suggestion_text_classes(pending_edit_count: @pending_edit_count)) do
            render_highlighted(@capability.description.to_s, @search_query)
          end
        else
          span(class: "italic text-gray-400 dark:text-gray-500") { "Add a description…" }
        end
        render_inline_editor_pencil(aria_label: "Edit capability description")
      end
      render_inline_editor_form(
        action: framework_capability_path(framework_id: @framework_id, id: @capability.capability_id),
        field_name: "capability[description]",
        current_value: @capability.description.to_s,
        rows: 3
      )
    end
  end
end
