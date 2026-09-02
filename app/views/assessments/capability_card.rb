# frozen_string_literal: true

# Card-per-capability in the assessment view.
#
# Replaced the old assessment matrix row, whose components were removed
# once nothing rendered them. Each capability is a standalone card with a
# horizontal level strip + optional expansion panel for the focused level.
#
class Views::Assessments::CapabilityCard < Views::Base
  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param viewer_is_manager [Boolean] whether the viewer is the manager-side
  #   party — threaded to the level strip's split chips
  # @param category [FrameworkState::CapabilityCategory]
  # @param scoring [Hash] primary scoring from MatrixDataBuilder
  # @param blocked [Boolean]
  # @param block_reason [String, nil]
  # @param contribution [Float, nil]
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param focused_level_ordinal [Integer, nil]
  # @param selected_levels [Hash{String => Integer}] per-capability selected
  #   level map (`stable_id => ordinal`); this card uses `selected_levels[stable_id]`
  # @param category_id [String, nil]
  # @param frozen [Boolean]
  # @param alignment_locked [Boolean]
  # @param viewer_person_id [String, nil]
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(capability_data:, merged_levels:, person_level:, assessment_id:,
                 context: :self, viewer_is_manager: false, category: nil, scoring: {},
                 blocked: false, block_reason: nil, contribution: nil,
                 expanded_capability_id: nil, focused_level_ordinal: nil,
                 selected_levels: {},
                 category_id: nil, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @capability_data = capability_data
    @capability = capability_data[:capability]
    @cells = capability_data[:cells]
    @merged_levels = merged_levels
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @viewer_is_manager = viewer_is_manager
    @category = category
    @scoring = scoring
    @blocked = blocked
    @block_reason = block_reason
    @contribution = contribution || capability_data[:contribution]
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_request_evidence = can_request_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin

    @is_url_focused = expanded_capability_id == @capability.stable_id
    # Each card renders the level the viewer last selected for THIS capability,
    # independently per capability — so a selection persists across scrolling,
    # rating, and broadcast reloads (`selected_levels` is the `levels[<id>]=<n>`
    # map). Falls back to the legacy single-focus pair (deep-links / Continue
    # CTA), then to the person's current level.
    @focused_ordinal =
      selected_levels[@capability.stable_id] ||
      (@is_url_focused ? (focused_level_ordinal || @person_level) : @person_level)
    # Guard against an ordinal that isn't a real level for this assessment
    # (stale shared link, hand-edited URL) — fall back to the person's level so
    # the expansion panel always renders something.
    unless @merged_levels.any? { |level| level[:ordinal] == @focused_ordinal }
      @focused_ordinal = @person_level
    end
    @category_id = category_id
  end

  def view_template
    # `data-focused` is the JS-managed source of truth for the
    # capability-focus ring. The server stamps it from `?capability=`
    # so the post-load look matches the URL; `matrix_controller#setFocus`
    # toggles it as the user clicks card headers or scrolls cards
    # past the sticky chrome. Styling stays in one place (Tailwind
    # data variants) regardless of who set the attribute.
    div(
      class: "rounded-xl border border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-900 p-4 transition-shadow " \
             "hover:shadow-sm " \
             "data-[focused=true]:shadow-sm " \
             "data-[focused=true]:ring-1 data-[focused=true]:ring-primary/20",
      # scroll-margin-top accounts for the unified sticky header. The
      # section sticky heading height varies per section (description
      # text wraps differently) so `matrix_controller#scrollCardUnderHeader`
      # overrides scroll-margin-top with the measured section height
      # right before scrolling.
      style: "scroll-margin-top: calc(var(--sticky-header-h, 0px) + 12px)",
      data: {
        matrix_target: "card",
        capability_id: @capability.capability_id,
        capability_stable_id: @capability.stable_id,
        focused: @is_url_focused.to_s
      }
    ) do
      card_header
      render Views::Assessments::LevelStrip.new(
        cells: @cells,
        merged_levels: @merged_levels,
        capability_stable_id: @capability.stable_id,
        person_level: @person_level,
        context: @context,
        viewer_is_manager: @viewer_is_manager,
        focused_ordinal: @focused_ordinal,
        alignment_locked: @alignment_locked
      )
      # Expansion always renders — every card auto-focuses the person's
      # current level (or the URL-specified level when present).
      expansion_panel
    end
  end

  private

  def card_header
    # The previous header carried a top-right "Add evidence" affordance
    # that duplicated the +/header affordance inside the expansion
    # panel (per-level evidence list), took a chunky border on mobile,
    # and pushed the contribution badge off into a separate column.
    # Removed — `contribution_badge` already right-aligns itself via
    # ml-auto inside capability_name.
    #
    # Click on the header sets capability-level focus so the activity
    # sidebar narrows to this capability. The handler lives on the
    # header (not the whole card) to keep clicks on the level strip
    # and expansion panel — which carry their own focus and interactive
    # affordances — out of this path. The level chips also
    # `event.stopPropagation()`, so even if the card were the handler
    # they wouldn't double-fire, but scoping to the header is the
    # cleaner contract.
    div(
      class: "min-w-0 mb-3 cursor-pointer select-none",
      data: { action: "click->matrix#focusCapability" }
    ) do
      eyebrow
      capability_name
      capability_description if @capability.description.present?
    end
  end

  def eyebrow
    return unless @category

    span(class: "text-[10px] font-medium text-gray-600 dark:text-gray-300 " \
                "uppercase tracking-wider") do
      @category.name
    end
  end

  def capability_name
    div(
      id: "capability-name-#{@capability.stable_id}",
      class: "flex items-center gap-2"
    ) do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white") do
        @capability.name
      end
      blocked_badge if @blocked
      contribution_badge
    end
  end

  def capability_description
    p(class: "text-xs text-gray-600 dark:text-gray-300 mt-0.5 line-clamp-2") do
      @capability.description
    end
  end

  # Signed delta vs the meeting-expectations baseline at the person's
  # current level (from `PersonDevelopment::Scoring#raw_contribution`).
  # Positive = over-performing for their level, negative = under,
  # 0 = exactly meeting. Rendered as `+0.5` / `-0.5` / `+0.0`. Hiding
  # the badge when negative — the previous behaviour — silently
  # dropped the most useful signal (under-performance).
  def contribution_badge
    return unless @contribution

    value = @contribution.to_f
    label = sprintf("%+.1f", value)
    color = if value >= 0.5
              "text-green-700 dark:text-green-400"
    elsif value > -0.5
              "text-gray-600 dark:text-gray-300"
    elsif value > -1.5
              "text-amber-700 dark:text-amber-400"
    else
              "text-red-700 dark:text-red-400"
    end
    span(class: "text-base font-bold tabular-nums #{color} ml-auto") { label }
  end

  def blocked_badge
    span(
      class: "text-[10px] font-medium text-red-700 dark:text-red-400 " \
             "bg-red-50 dark:bg-red-900/20 px-1.5 py-0.5 rounded",
      title: @block_reason
    ) { "Blocked" }
  end

  def expansion_panel
    focused_level = @merged_levels.find { |l| l[:ordinal] == @focused_ordinal }
    cell_data = @cells[@focused_ordinal]
    return unless cell_data && focused_level

    render Views::Assessments::CapabilityCardExpansion.new(
      cell_data: cell_data,
      capability: @capability,
      level: focused_level,
      capability_stable_id: @capability.stable_id,
      ordinal: @focused_ordinal,
      person_level: @person_level,
      assessment_id: @assessment_id,
      context: @context,
      category_id: @category_id,
      frozen: @frozen,
      alignment_locked: @alignment_locked,
      viewer_person_id: @viewer_person_id,
      can_create_evidence: @can_create_evidence,
      can_request_evidence: @can_request_evidence,
      can_relink_others_evidence: @can_relink_others_evidence,
      can_comment: @can_comment,
      viewer_is_tenant_admin: @viewer_is_tenant_admin
    )
  end
end
