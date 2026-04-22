# frozen_string_literal: true

# Compact list of pending suggestions, embedded as a Turbo Frame in the
# framework explorer's right pane.
#
# Renders only pending suggestions by default. The frame is wrapped so it
# can be reloaded by the explorer when the focused entity or filter changes.
#
class Views::Frameworks::Suggestions::PanelFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag

  STATUS_VARIANTS = {
    "pending" => :warning,
    "approved" => :success,
    "rejected" => :default,
    "withdrawn" => :default
  }.freeze

  ENTITY_TYPE_LABELS = Views::Frameworks::Suggestions::IndexView::ENTITY_TYPE_LABELS
  CONTENT_KEYS = Views::Frameworks::Suggestions::IndexView::CONTENT_KEYS

  # @param framework [FrameworkState::Framework]
  # @param suggestions [Array<FrameworkState::SuggestedEdit>]
  # @param focus_descriptor [Hash] { level:, category_name:, capability_name:, level_label: }
  # @param context_labels [Hash{String => String}] suggestion_id => role/level label
  # @param navigation_coords [Hash{String => Hash}] suggestion_id => { level:, category_id:, ... }
  # @param clear_path [String, nil] URL that clears focus (framework-wide panel)
  def initialize(framework:, suggestions:, focus_descriptor: { level: :framework },
                 context_labels: {}, navigation_coords: {}, clear_path: nil)
    @framework = framework
    @suggestions = suggestions
    @focus_descriptor = focus_descriptor
    @context_labels = context_labels
    @navigation_coords = navigation_coords
    @clear_path = clear_path
  end

  def view_template
    turbo_frame_tag("suggestion-panel") do
      div(class: "h-full flex flex-col") do
        header
        body
      end
    end
  end

  private

  def header
    div(class: "px-4 py-3 border-b border-gray-200 dark:border-gray-700 " \
                "flex items-start justify-between gap-2") do
      div(class: "min-w-0 flex-1") do
        h2(class: "text-sm font-semibold text-gray-900 dark:text-white truncate",
           data: { suggestion_panel_target: "focusTitle" }) do
          focus_title
        end
        p(class: "text-xs text-gray-500 dark:text-gray-400 mt-0.5") do
          pending_count = pending.size
          "#{pending_count} pending"
        end
        clear_focus_link if focused?
      end
      a(
        href: framework_suggestions_path(@framework.framework_id),
        class: "text-xs text-primary hover:text-primary/80 shrink-0",
        data: { turbo_frame: "_top" }
      ) { "View all" }
    end
  end

  def clear_focus_link
    return unless @clear_path

    a(
      href: @clear_path,
      class: "text-xs text-gray-500 dark:text-gray-400 hover:text-primary mt-1 inline-block",
      data: {
        turbo_frame: "suggestion-panel",
        action: "click->context-pane#clearFocus"
      }
    ) { "\u2190 Show all framework suggestions" }
  end

  def focus_title
    case @focus_descriptor[:level]
    when :category
      "#{@focus_descriptor[:category_name]} \u2014 category"
    when :capability
      @focus_descriptor[:capability_name].to_s
    when :cell
      "#{@focus_descriptor[:capability_name]} \u00d7 #{@focus_descriptor[:level_label]}"
    else
      "All framework suggestions"
    end
  end

  def focused?
    @focus_descriptor[:level] && @focus_descriptor[:level] != :framework
  end

  def body
    div(class: "flex-1 overflow-y-auto") do
      if pending.empty?
        empty_state
      else
        ul(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          pending.each { |s| panel_row(s) }
        end
      end
    end
  end

  def empty_state
    div(class: "p-6 text-center text-sm text-gray-400 dark:text-gray-500") do
      p { "No pending suggestions." }
    end
  end

  def panel_row(suggestion)
    label = @context_labels[suggestion.suggestion_id]
    coords = @navigation_coords[suggestion.suggestion_id]

    li(class: "group") do
      div(class: "px-4 py-3") do
        # Badges + detail link on same line
        div(class: "flex items-center gap-1.5 mb-1") do
          render Components::Kit::Badge.new(entity_label(suggestion), variant: :info)
          render Components::Kit::Badge.new(kind_label(suggestion), variant: kind_variant(suggestion))
          detail_link(suggestion)
        end

        # Clickable body — navigates the matrix to the relevant entity
        navigate_body(suggestion, label: label, coords: coords)
      end
    end
  end

  # The main click area — sets explorer focus to the suggestion's entity.
  def navigate_body(suggestion, label:, coords:)
    data = if coords
      {
        action: "click->context-pane#focusSuggestion",
        nav_level: coords[:level],
        nav_category_id: coords[:category_id],
        nav_capability_id: coords[:capability_id],
        nav_level_ordinal: coords[:level_ordinal]
      }.compact
    else
      {}
    end

    # Button (not div) for the navigable case so keyboard users can focus
    # + Enter to navigate. The non-navigable case (no coords) stays a div
    # to avoid a non-functional button landing in the tab order.
    wrapper_class = "#{'w-full text-left cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800/50 ' if coords}" \
                    "-mx-4 -mb-3 px-4 pb-3 pt-0.5 rounded-b transition-colors"
    wrapper_attrs = { class: wrapper_class }
    wrapper_attrs[:data] = data if data.any?

    if coords
      wrapper_attrs[:type] = "button"
      button(**wrapper_attrs) { navigate_body_content(suggestion, label) }
    else
      div(**wrapper_attrs) { navigate_body_content(suggestion, label) }
    end
  end

  def navigate_body_content(suggestion, label)
    if label
      p(class: "text-xs text-gray-500 dark:text-gray-400 mb-0.5") { plain label }
    end
    p(class: "text-xs text-gray-700 dark:text-gray-300 line-clamp-2") do
      plain suggestion_preview(suggestion)
    end
  end

  # Small link to the suggestion detail page.
  def detail_link(suggestion)
    a(
      href: framework_suggestion_path(@framework.framework_id, suggestion.suggestion_id),
      class: "ml-auto text-gray-400 dark:text-gray-500 hover:text-primary " \
             "focus-visible:text-primary focus-visible:opacity-100 " \
             "focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2 " \
             "opacity-0 group-hover:opacity-100 transition-opacity shrink-0",
      data: { turbo_frame: "_top" },
      title: "View suggestion details",
      aria_label: "View suggestion details"
    ) do
      svg(
        xmlns: "http://www.w3.org/2000/svg", fill: "none", viewbox: "0 0 24 24",
        stroke_width: "1.5", stroke: "currentColor", class: "w-4 h-4"
      ) do |s|
        s.path(
          stroke_linecap: "round", stroke_linejoin: "round",
          d: "M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
        )
      end
    end
  end

  def pending
    @pending ||= @suggestions.select { |s| s.status == "pending" }
  end

  def suggestion_preview(suggestion)
    case suggestion.kind
    when "create"
      creation_preview(suggestion.proposed_attributes || {})
    when "delete"
      suggestion.current_value.to_s
    else
      suggestion.suggested_value.to_s
    end
  end

  # Prefers human-readable content keys over IDs when previewing a create.
  #
  # @param attrs [Hash]
  # @return [String]
  def creation_preview(attrs)
    normalized = attrs.transform_keys(&:to_s)
    CONTENT_KEYS.each do |key|
      value = normalized[key]
      return value.to_s if value.present?
    end
    normalized.values.select(&:present?).first.to_s
  end

  def entity_label(suggestion)
    ENTITY_TYPE_LABELS.fetch(suggestion.target_entity_type, suggestion.target_entity_type.humanize)
  end

  def kind_label(suggestion)
    case suggestion.kind
    when "create" then "New"
    when "delete" then "Delete"
    else "Edit"
    end
  end

  def kind_variant(suggestion)
    case suggestion.kind
    when "create" then :success
    when "delete" then :warning
    else :default
    end
  end
end
