# frozen_string_literal: true

# The framework activity feed, embedded as a Turbo Frame in the explorer's
# right-hand context pane. Generalises the old suggestions-only PanelFrame:
# suggestions are now one filter group within a full lifecycle feed.
#
# Keeps the `suggestion-panel` Turbo Frame id and the focus header /
# clear-focus affordances so the existing context_pane_controller wiring
# (focus protocol, frame reload, navigation) continues to drive it.
#
class Views::Frameworks::Activity::PanelFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag

  # @param framework [FrameworkState::Framework]
  # @param entries [Array<Frameworks::ActivityFeedQuery::Entry>] reverse-chronological
  # @param focus_descriptor [Hash] { level:, category_name:, capability_name:, level_label: }
  # @param clear_path [String, nil] URL that clears focus (framework-wide feed)
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] per-viewer
  #   approval authority; drives whether a pending-suggestion entry is actionable
  def initialize(framework:, entries:, focus_descriptor: { level: :framework }, clear_path: nil,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @framework = framework
    @entries = entries
    @focus_descriptor = focus_descriptor
    @clear_path = clear_path
    @approval_authority = approval_authority
  end

  def view_template
    turbo_frame_tag("suggestion-panel") do
      div(class: "h-full flex flex-col", data: { controller: "framework-activity" }) do
        header
        body
      end
    end
  end

  private

  def header
    div(class: "px-4 py-3 border-b border-gray-200 dark:border-gray-700") do
      div(class: "flex items-start justify-between gap-2") do
        div(class: "min-w-0 flex-1") do
          h2(class: "text-sm font-semibold text-gray-900 dark:text-white truncate") { focus_title }
          p(class: "text-xs text-gray-600 dark:text-gray-300 mt-0.5") do
            "#{@entries.size} #{@entries.size == 1 ? 'event' : 'events'}"
          end
          clear_focus_link if focused?
        end
        # Links to the standalone suggestion-review index — name the
        # destination, since the feed itself covers more than suggestions and
        # there is no separate full-activity index page.
        a(
          href: framework_suggestions_path(@framework.framework_id),
          class: "text-xs text-primary hover:text-primary/80 shrink-0",
          data: { turbo_frame: "_top" },
          title: "Open the full suggestion-review page"
        ) { "All suggestions" }
      end
      div(class: "mt-2") { render Views::Frameworks::Activity::FilterChips.new }
    end
  end

  def clear_focus_link
    return unless @clear_path

    a(
      href: @clear_path,
      class: "text-xs text-gray-600 dark:text-gray-300 hover:text-primary mt-1 inline-block",
      data: {
        turbo_frame: "suggestion-panel",
        action: "click->context-pane#clearFocus"
      }
    ) { "← Show all framework activity" }
  end

  def focus_title
    case @focus_descriptor[:level]
    when :category
      "#{@focus_descriptor[:category_name]} — category"
    when :capability
      @focus_descriptor[:capability_name].to_s
    when :cell
      "#{@focus_descriptor[:capability_name]} × #{@focus_descriptor[:level_label]}"
    else
      "All framework activity"
    end
  end

  def focused?
    @focus_descriptor[:level] && @focus_descriptor[:level] != :framework
  end

  def body
    div(class: "flex-1 overflow-y-auto p-4") do
      if @entries.empty?
        empty_state
      else
        ul(class: "space-y-1") do
          @entries.each do |entry|
            render Views::Frameworks::Activity::Entry.new(
              entry: entry,
              framework_id: @framework.framework_id,
              approval_authority: @approval_authority
            )
          end
        end
      end
    end
  end

  def empty_state
    div(class: "rounded-lg border border-dashed border-gray-200 dark:border-gray-700 " \
               "p-4 text-center text-xs text-gray-600 dark:text-gray-300") do
      "No activity yet."
    end
  end
end
