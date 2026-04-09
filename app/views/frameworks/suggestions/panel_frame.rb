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

  # @param framework [FrameworkState::Framework]
  # @param suggestions [Array<FrameworkState::SuggestedEdit>]
  def initialize(framework:, suggestions:)
    @framework = framework
    @suggestions = suggestions
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
                "flex items-center justify-between") do
      div do
        h2(class: "text-sm font-semibold text-gray-900 dark:text-white") { "Suggestions" }
        p(class: "text-xs text-gray-500 dark:text-gray-400") do
          pending_count = pending.size
          "#{pending_count} pending"
        end
      end
      a(
        href: framework_suggestions_path(@framework.framework_id),
        class: "text-xs text-primary hover:text-primary/80",
        data: { turbo_frame: "_top" }
      ) { "View all" }
    end
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
    li do
      a(
        href: framework_suggestion_path(@framework.framework_id, suggestion.suggestion_id),
        class: "block px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors",
        data: { turbo_frame: "_top" }
      ) do
        div(class: "flex items-center gap-2 mb-1") do
          render Components::Kit::Badge.new(entity_label(suggestion))
          render Components::Kit::Badge.new(
            "T#{review_tier(suggestion)}",
            variant: tier_variant(review_tier(suggestion))
          )
        end
        p(class: "text-xs text-gray-700 dark:text-gray-300 line-clamp-2") do
          plain suggestion.suggested_value.to_s
        end
      end
    end
  end

  def pending
    @pending ||= @suggestions.select { |s| s.status == "pending" }
  end

  def entity_label(suggestion)
    ENTITY_TYPE_LABELS.fetch(suggestion.target_entity_type, suggestion.target_entity_type.humanize)
  end

  def review_tier(suggestion)
    case suggestion.target_entity_type
    when "role_illustration" then 1
    when "behavioural_expectation" then 3
    else 2
    end
  end

  def tier_variant(tier)
    case tier
    when 3 then :warning
    when 2 then :info
    else :default
    end
  end
end
