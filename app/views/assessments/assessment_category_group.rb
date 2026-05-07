# frozen_string_literal: true

# Unified category header + child capability rows in the assessment matrix.
#
# Perspective-aware: uses the primary scoring perspective (based on context)
# for category contribution labels, pass/fail status, and capability
# blocked/contribution indicators. Shows divergence when secondary
# perspectives disagree on category pass/fail.
#
class Views::Assessments::AssessmentCategoryGroup < Views::Base
  # @param category_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param scoring [Hash] effective scoring output
  # @param self_scoring [Hash, nil] self-only perspective scoring
  # @param manager_scoring [Hash, nil] manager-only perspective scoring
  # @param aligned_scoring [Hash, nil] aligned-only perspective scoring
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param show_header [Boolean] whether to render the sticky category header row
  # @param frozen [Boolean] whether self/manager rating cells are read-only (alignment in progress)
  # @param alignment_locked [Boolean] whether alignment cells are read-only (alignment completed)
  # @param viewer_person_id [String, nil] threaded through to the evidence section
  # @param can_create_evidence [Boolean] threaded through to the evidence section
  # @param can_relink_others_evidence [Boolean] threaded through to the evidence section
  def initialize(category_data:, merged_levels:, person_level:, scoring:, assessment_id:, context: :self,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil,
                 expanded_capability_id: nil, show_header: true, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false)
    @category_data = category_data
    @category = category_data[:category]
    @merged_levels = merged_levels
    @person_level = person_level
    @scoring = scoring
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @assessment_id = assessment_id
    @context = context
    @expanded_capability_id = expanded_capability_id
    @show_header = show_header
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
  end

  def view_template
    if @show_header
      sticky_cols = [ @merged_levels.size, 1 ].min + 1
      filler_cols = @merged_levels.size + 1 - sticky_cols

      tr(class: "sticky top-[41px] z-[5]") do
        td(
          colspan: sticky_cols,
          class: "sticky left-0 z-[6] px-4 py-2 bg-gray-100 dark:bg-gray-800 border-b border-r " \
                 "border-gray-200 dark:border-gray-700 min-w-[220px]"
        ) do
          category_header
        end

        if filler_cols > 0
          td(
            colspan: filler_cols,
            class: "bg-gray-100 dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700"
          )
        end
      end
    end

    @category_data[:capabilities].each do |cap_data|
      stable_id = cap_data[:capability].stable_id
      blocked = primary_scoring.dig(:capability_statuses, stable_id) == :blocked
      block_reason = primary_scoring.dig(:block_reasons, stable_id)
      contribution = primary_scoring.dig(:capability_contributions, stable_id) || cap_data[:contribution]

      render Views::Assessments::AssessmentRow.new(
        capability_data: cap_data,
        merged_levels: @merged_levels,
        person_level: @person_level,
        assessment_id: @assessment_id,
        context: @context,
        blocked: blocked,
        block_reason: block_reason,
        contribution: contribution,
        secondary_contributions: secondary_capability_contributions(stable_id),
        expanded: stable_id == @expanded_capability_id,
        category_id: @category.category_id,
        frozen: @frozen,
        alignment_locked: @alignment_locked,
        viewer_person_id: @viewer_person_id,
        can_create_evidence: @can_create_evidence,
        can_relink_others_evidence: @can_relink_others_evidence
      )
    end
  end

  private

  def category_header
    cat_id = @category.category_id
    primary_result = primary_scoring[:category_results]&.dig(cat_id)

    div(class: "flex items-center justify-between gap-2") do
      div(class: "flex items-center gap-2") do
        span(class: "text-sm font-semibold text-gray-900 dark:text-white") { @category.name }
        render Components::Kit::CategoryToleranceIndicator.new(
          threshold: @category_data[:deficit_threshold]
        )
      end

      render Views::Assessments::CategoryIndicators.new(
        category_id: cat_id,
        category_result: primary_result,
        secondary_results: secondary_category_results(cat_id)
      )
    end
  end

  # Returns the primary scoring hash based on the current context.
  # Falls back to effective scoring if the perspective-specific scoring is nil.
  #
  # @return [Hash]
  def primary_scoring
    @primary_scoring ||=
      case @context
      when :self      then @self_scoring || @scoring
      when :manager   then @manager_scoring || @scoring
      when :alignment then @aligned_scoring || @scoring
      else @scoring
      end
  end

  # Returns an array of [label, scoring] pairs for secondary perspectives.
  # Excludes nil scorings and the primary perspective.
  #
  # @return [Array<Array(String, Hash)>]
  def secondary_scorings
    @secondary_scorings ||= begin
      all = []
      case @context
      when :self
        all << [ "Mgr", @manager_scoring ] if @manager_scoring
        all << [ "Agreed", @aligned_scoring ] if @aligned_scoring
      when :manager
        all << [ "Self", @self_scoring ] if @self_scoring
        all << [ "Agreed", @aligned_scoring ] if @aligned_scoring
      when :alignment
        all << [ "Self", @self_scoring ] if @self_scoring
        all << [ "Mgr", @manager_scoring ] if @manager_scoring
      end
      all
    end
  end

  # Returns secondary category results for divergence display.
  #
  # @param category_id [String]
  # @return [Array<Array(String, Hash)>] [["Mgr", { pass:, pool: }], ...]
  def secondary_category_results(category_id)
    secondary_scorings.filter_map do |label, scoring|
      result = scoring[:category_results]&.dig(category_id)
      next unless result

      [ label, result ]
    end
  end

  # Returns secondary capability contributions for divergence display.
  #
  # @param stable_id [String]
  # @return [Array<Array(String, Float)>] [["Mgr", -0.5], ...]
  def secondary_capability_contributions(stable_id)
    secondary_scorings.filter_map do |label, scoring|
      contribution = scoring.dig(:capability_contributions, stable_id)
      next unless contribution

      [ label, contribution ]
    end
  end
end
