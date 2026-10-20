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

  # The focus chain ("Category › Capability › L2").
  BREADCRUMB_ID = "framework-activity-focus-breadcrumb"

  # @param framework [FrameworkState::Framework]
  # @param entries [Array<Frameworks::ActivityFeedQuery::Entry>] reverse-chronological
  # @param focus_descriptor [Hash] { level:, category_name:, capability_name:, level_label: }
  # @param clear_path [String, nil] URL that clears focus (framework-wide feed)
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] per-viewer
  #   approval authority; drives whether a pending-suggestion entry is actionable
  def initialize(framework:, entries:, focus_descriptor: { level: :framework }, clear_path: nil,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 has_more: false, load_more_path: nil, total_loaded: nil)
    @framework = framework
    @entries = entries
    @focus_descriptor = focus_descriptor
    @clear_path = clear_path
    @approval_authority = approval_authority
    @has_more = has_more
    @load_more_path = load_more_path
    @total_loaded = total_loaded || entries.size
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
    div(class: "px-4 py-3 border-b border-default") do
      div(class: "flex items-start justify-between gap-2") do
        div(class: "min-w-0 flex-1") do
          h2(class: "text-sm font-semibold text-default truncate") { focus_title }
          focused? ? focus_breadcrumb : focus_hint
          # Count reflects entries loaded so far (running total across batches);
          # the "load older" Turbo Stream replaces this with the new total.
          render Views::Frameworks::Activity::Count.new(total: @total_loaded)
          clear_focus_link if focused?
        end
        # Links to the standalone suggestion-review index — name the
        # destination, since the feed itself covers more than suggestions and
        # there is no separate full-activity index page.
        a(
          href: framework_suggestions_path(@framework.framework_id),
          class: "text-xs text-link hover:text-link-hover hover:underline shrink-0",
          data: { turbo_frame: "_top" },
          title: "Open the full suggestion-review page"
        ) { "All suggestions" }
      end
      div(class: "mt-2") { render Views::Frameworks::Activity::FilterChips.new }
    end
  end

  # The gestures that narrow this feed are three different clicks on the grid,
  # discoverable only by accident — so the unfocused header names them. It is
  # replaced by the breadcrumb the moment focus is set, so the hint is on screen
  # exactly while it is actionable (#382).
  def focus_hint
    p(class: "mt-1 text-[11px] text-muted") do
      "Click a category name, expand a capability row, or click inside an " \
        "expanded cell to narrow this feed."
    end
  end

  # The focus chain — "Thinking › Strategic Thinking › L2" — with an × that
  # clears it. Two things the bare title could not do: name the CATEGORY a
  # focused capability sits in, and put the clear affordance next to the thing
  # being cleared. Focus is set by three different grid gestures (category name,
  # row expand, expanded-cell background) and cleared by others, so one place
  # that both shows and clears it is the whole point (#382).
  #
  # The × is the same clear path as the worded link below — an `<a>` to the
  # unfocused feed, plus `context-pane#clearFocus`, which dispatches
  # `suggestion:navigate { level: "framework" }` so the grid drops its ring and
  # collapses the expanded row too.
  def focus_breadcrumb
    segments = breadcrumb_segments
    return if segments.empty?

    div(class: "mt-1 flex items-start gap-1 text-[11px] text-muted") do
      # Stable id so a test can assert the ordered chain rather than the
      # presence of a name — "Thinking" is a substring of "Strategic Thinking",
      # so a substring check proves nothing about the category segment.
      div(id: BREADCRUMB_ID, class: "min-w-0 flex-1") do
        segments.each_with_index do |segment, index|
          span(class: "text-subtle", aria: { hidden: "true" }) { " › " } if index.positive?
          span { segment }
        end
      end
      clear_focus_button
    end
  end

  # Icon-only, so it wraps its small glyph in a 44px box rather than shipping a
  # 44px ×, and takes the AA-safe muted pairing — an affordance, not a
  # decorative separator (phlex-views.md → Accessibility).
  def clear_focus_button
    return unless @clear_path

    a(
      href: @clear_path,
      class: "shrink-0 inline-flex items-center justify-center min-w-11 min-h-11 -my-3 " \
             "rounded text-base leading-none text-muted hover:text-brand",
      title: "Clear focus",
      aria_label: "Clear focus",
      data: {
        turbo_frame: "suggestion-panel",
        action: "click->context-pane#clearFocus"
      }
    ) { "×" }
  end

  # Most general first. A category's own breadcrumb is just its name — the ×
  # is what the line adds there.
  def breadcrumb_segments
    [
      @focus_descriptor[:category_name],
      @focus_descriptor[:capability_name],
      @focus_descriptor[:level_label]
    ].compact_blank
  end

  def clear_focus_link
    return unless @clear_path

    a(
      href: @clear_path,
      class: "text-xs text-muted hover:text-brand mt-1 inline-block",
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
    # scroller target: the context-pane controller preserves this element's
    # scrollTop across same-content frame reloads (broadcasts, post-submit) —
    # a reviewer working down a long feed must not be thrown back to the top
    # after every approval.
    div(class: "flex-1 overflow-y-auto p-4", data: { context_pane_target: "scroller" }) do
      if @entries.empty?
        empty_state
      else
        # Stable id so the "load older" Turbo Stream can append the next batch.
        ul(id: "framework-activity-list", class: "space-y-1") do
          @entries.each do |entry|
            render Views::Frameworks::Activity::Entry.new(
              entry: entry,
              framework_id: @framework.framework_id,
              approval_authority: @approval_authority
            )
          end
        end
        render Views::Frameworks::Activity::LoadMore.new(
          has_more: @has_more, load_more_path: @load_more_path
        )
      end
    end
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "No activity yet", size: :panel)
  end
end
