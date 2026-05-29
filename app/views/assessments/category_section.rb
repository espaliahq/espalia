# frozen_string_literal: true

# Anchor-target section for one capability category.
# Renders a section heading and a stack of CapabilityCards.
#
class Views::Assessments::CategorySection < Views::Base
  # @param category_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param scoring [Hash] primary scoring
  # @param self_scoring [Hash, nil]
  # @param manager_scoring [Hash, nil]
  # @param aligned_scoring [Hash, nil]
  # @param expanded_capability_id [String, nil]
  # @param focused_level_ordinal [Integer, nil]
  # @param frozen [Boolean]
  # @param alignment_locked [Boolean]
  # @param viewer_person_id [String, nil]
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(category_data:, merged_levels:, person_level:, assessment_id:,
                 context: :self, scoring: {}, self_scoring: nil,
                 manager_scoring: nil, aligned_scoring: nil,
                 expanded_capability_id: nil, focused_level_ordinal: nil,
                 frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @category_data = category_data
    @category = category_data[:category]
    @merged_levels = merged_levels
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @scoring = scoring
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @expanded_capability_id = expanded_capability_id
    @focused_level_ordinal = focused_level_ordinal
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
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

  private

  def section_header
    # Sticky just under the unified header. `top: var(--sticky-header-h)`
    # is published by `category_nav_controller` whenever the header
    # resizes. The negative `-mx-6 px-6` extends the heading background
    # to the page edges so capability cards scroll underneath it
    # cleanly. z-10 keeps it under the z-20 unified header.
    div(
      class: "md:sticky md:z-10 -mx-6 px-6 py-3 mb-3 " \
             "bg-gray-50/95 dark:bg-gray-950/95 md:backdrop-blur-sm " \
             "flex items-baseline justify-between gap-3",
      # Stable hook for matrix_controller#scrollCardUnderHeader — the
      # sticky flavour now varies by viewport (`md:sticky`), so a
      # class-name selector would silently miss this element.
      data: { section_header: "true" },
      style: "top: var(--sticky-header-h, 0px)"
    ) do
      div(class: "min-w-0") do
        h2(class: "text-lg font-bold text-gray-900 dark:text-white") do
          @category.name
        end
        if @category.description.present?
          p(class: "text-sm text-gray-500 dark:text-gray-400 mt-0.5") do
            @category.description
          end
        end
      end
      render Views::Assessments::CategoryIndicators.new(
        category_id: @category.category_id,
        category_result: primary_scoring_for_context[:category_results]&.dig(@category.category_id),
        secondary_results: secondary_category_results,
        category_data: @category_data,
        context: @context
      )
    end
  end

  # Pairs each labelled secondary perspective with its result for this
  # category, dropping perspectives that have no scoring or no result for
  # this category — matches the shape rating controllers thread in for
  # the turbo-replace path so initial render and post-rate render agree.
  def secondary_category_results
    perspectives =
      case @context
      when :self      then [ [ "Mgr",  @manager_scoring ], [ "Agreed", @aligned_scoring ] ]
      when :manager   then [ [ "Self", @self_scoring ],    [ "Agreed", @aligned_scoring ] ]
      when :alignment then [ [ "Self", @self_scoring ],    [ "Mgr",    @manager_scoring ] ]
      else []
      end

    perspectives.filter_map do |label, scoring|
      next unless scoring

      result = scoring[:category_results]&.dig(@category.category_id)
      next unless result

      [ label, result ]
    end
  end

  def capability_cards
    statuses = primary_scoring_for_context[:capability_statuses] || {}
    reasons  = primary_scoring_for_context[:block_reasons] || {}
    contributions = primary_scoring_for_context[:capability_contributions] || {}

    div(class: "space-y-3") do
      @category_data[:capabilities].each do |cap_data|
        stable_id = cap_data[:capability].stable_id
        render Views::Assessments::CapabilityCard.new(
          capability_data: cap_data,
          merged_levels: @merged_levels,
          person_level: @person_level,
          assessment_id: @assessment_id,
          context: @context,
          category: @category,
          scoring: primary_scoring_for_context,
          blocked: statuses[stable_id] == :blocked,
          block_reason: reasons[stable_id],
          contribution: contributions[stable_id],
          expanded_capability_id: @expanded_capability_id,
          focused_level_ordinal: @focused_level_ordinal,
          category_id: @category.category_id,
          frozen: @frozen,
          alignment_locked: @alignment_locked,
          viewer_person_id: @viewer_person_id,
          can_create_evidence: @can_create_evidence,
          can_relink_others_evidence: @can_relink_others_evidence,
          can_comment: @can_comment,
          viewer_is_tenant_admin: @viewer_is_tenant_admin
        )
      end
    end
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
