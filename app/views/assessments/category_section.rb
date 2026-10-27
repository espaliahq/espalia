# frozen_string_literal: true

# Anchor-target section for one capability category.
# Renders a section heading and a stack of CapabilityCards.
#
class Views::Assessments::CategorySection < Views::Base
  # @param category_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param thresholds [Hash] the framework's own bands, for the definitions
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param viewer_is_manager [Boolean] whether the viewer is the manager-side
  #   party — threaded to each capability card's split chips
  # @param scoring [Hash] primary scoring
  # @param self_scoring [Hash, nil]
  # @param manager_scoring [Hash, nil]
  # @param aligned_scoring [Hash, nil]
  # @param expanded_capability_id [String, nil]
  # @param focused_level_ordinal [Integer, nil]
  # @param selected_levels [Hash{String => Integer}] per-capability selected
  #   level map (`stable_id => ordinal`)
  # @param frozen [Boolean]
  # @param alignment_locked [Boolean]
  # @param viewer_person_id [String, nil]
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(category_data:, merged_levels:, person_level:, assessment_id:, thresholds: {},
                 context: :self, viewer_is_manager: false, scoring: {}, self_scoring: nil,
                 manager_scoring: nil, aligned_scoring: nil,
                 expanded_capability_id: nil, focused_level_ordinal: nil,
                 selected_levels: {},
                 frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false, lens: nil)
    @lens = lens
    @category_data = category_data
    @category = category_data[:category]
    @merged_levels = merged_levels
    @person_level = person_level
    @thresholds = thresholds
    @assessment_id = assessment_id
    @context = context
    @viewer_is_manager = viewer_is_manager
    @scoring = scoring
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @expanded_capability_id = expanded_capability_id
    @focused_level_ordinal = focused_level_ordinal
    @selected_levels = selected_levels
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_request_evidence = can_request_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
  end

  def view_template
    section(
      id: "category-#{@category.category_id}",
      class: "scroll-mt-40",
      data: { category_id: @category.category_id }
    ) do
      section_header
      capability_cards
    end
  end

  # One of this section's cards, unrendered, built as the section builds it.
  #
  # @param stable_id [String]
  # @return [Views::Assessments::CapabilityCard, nil] nil when the section
  #   doesn't hold it
  def capability_card(stable_id)
    cap_data = @category_data[:capabilities].find { |cap| cap[:capability].stable_id == stable_id }
    card_for(cap_data) if cap_data
  end

  private

  # Bulk confirm is the viewer's own side on the home role; frozen covers a
  # started alignment and a viewer without rating authority alike.
  def confirm_href
    Views::Assessments::CategoryIndicators.confirm_href(
      assessment_id: @assessment_id, category_id: @category.category_id, context: @context,
      frozen: @frozen, home: @lens.nil? || @lens.home?
    )
  end

  def section_header
    # Sticky just under the unified header. `top: var(--sticky-header-h)`
    # is published by `category_nav_controller` whenever the header
    # resizes. The negative `-mx-6 px-6` extends the heading background
    # to the page edges so capability cards scroll underneath it
    # cleanly. z-10 keeps it under the z-20 unified header.
    div(
      class: "md:sticky md:z-10 -mx-6 px-6 py-3 mb-3 " \
             "bg-page/95 md:backdrop-blur-sm " \
             "flex flex-col gap-0.5",
      # Stable hook for matrix_controller#scrollCardUnderHeader — the
      # sticky flavour now varies by viewport (`md:sticky`), so a
      # class-name selector would silently miss this element.
      data: { section_header: "true" },
      style: "top: var(--sticky-header-h, 0px)"
    ) do
      # The name shares its line with the score; the description gets the
      # whole width underneath. Sharing one row with the ~14rem score
      # cluster left the description a ribbon four or five words wide —
      # prose needs the column, and a name is short enough not to.
      # Wrapping is allowed so a narrow viewport drops the score below the
      # name rather than crushing it.
      div(class: "flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1") do
        h2(class: "text-lg font-bold text-default min-w-0") do
          @category.name
        end
        render Views::Assessments::CategoryIndicators.new(
          category_id: @category.category_id,
          category_score: primary_scoring_for_context.dig(:category_scores, @category.category_id),
          secondary_scores: secondary_category_scores,
          category_data: @category_data,
          context: @context,
          merged_levels: @merged_levels,
          person_level: @person_level,
          thresholds: @thresholds,
          viewer_is_manager: @viewer_is_manager,
          confirm_href: confirm_href
        )
      end
      if @category.description.present?
        p(class: "text-sm text-muted max-w-3xl") do
          @category.description
        end
      end
    end
  end

  # One category's secondary perspectives, through the shared definition
  # so the section header and the rating controllers' Turbo Stream
  # responses cannot drift.
  def secondary_category_scores
    Assessments::SecondaryPerspectives.category_scores(
      { self_scoring: @self_scoring, manager_scoring: @manager_scoring, aligned_scoring: @aligned_scoring },
      @context, @category.category_id
    )
  end

  def capability_cards
    div(class: "space-y-3") do
      @category_data[:capabilities].each { |cap_data| render card_for(cap_data) }
    end
  end

  def card_for(cap_data)
    stable_id = cap_data[:capability].stable_id
    Views::Assessments::CapabilityCard.new(
      capability_data: cap_data,
      merged_levels: @merged_levels,
      person_level: @person_level,
      thresholds: @thresholds,
      assessment_id: @assessment_id,
      context: @context,
      viewer_is_manager: @viewer_is_manager,
      category: @category,
      scoring: primary_scoring_for_context,
      blocked: primary_scoring_for_context.dig(:capability_statuses, stable_id) == :blocked,
      block_reason: primary_scoring_for_context.dig(:block_reasons, stable_id),
      expanded_capability_id: @expanded_capability_id,
      focused_level_ordinal: @focused_level_ordinal,
      selected_levels: @selected_levels,
      category_id: @category.category_id,
      frozen: @frozen,
      alignment_locked: @alignment_locked,
      viewer_person_id: @viewer_person_id,
      can_create_evidence: @can_create_evidence,
      can_request_evidence: @can_request_evidence,
      can_relink_others_evidence: @can_relink_others_evidence,
      can_comment: @can_comment,
      viewer_is_tenant_admin: @viewer_is_tenant_admin,
      lens: @lens
    )
  end

  def primary_scoring_for_context
    @primary_scoring_for_context ||=
      case @context
      when :self      then @self_scoring || @scoring
      when :manager   then @manager_scoring || @scoring
      when :alignment then @aligned_scoring || @scoring
      else @scoring
      end
  end
end
