# frozen_string_literal: true

# Expansion panel below the level strip when a level chip is focused.
#
# Shows expectation text, interactive FrequencySelector (or read-only bar),
# secondary perspective bars, illustrations, evidence, and comments for
# the focused capability × level cell.
#
class Views::Assessments::CapabilityCardExpansion < Views::Base
  # @param cell_data [Hash] from MatrixDataBuilder
  # @param capability [FrameworkState::Capability]
  # @param level [Hash] the focused level from merged_levels
  # @param capability_stable_id [String]
  # @param ordinal [Integer]
  # @param person_level [Integer]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param category_id [String, nil]
  # @param frozen [Boolean]
  # @param alignment_locked [Boolean]
  # @param viewer_person_id [String, nil]
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(cell_data:, capability:, level:, capability_stable_id:,
                 ordinal:, person_level:, assessment_id:, context: :self,
                 category_id: nil, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @cell_data = cell_data
    @capability = capability
    @level = level
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @category_id = category_id
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
  end

  def view_template
    # No outer border / background — the parent capability card already
    # carries those. A thin top border + a little top padding visually
    # separates the expansion from the level strip without the boxed-
    # in-a-box look.
    div(
      id: "expansion-#{@capability_stable_id}",
      class: "mt-3 pt-3 border-t border-gray-200 dark:border-gray-700"
    ) do
      expansion_header
      expectation_sentence
      diverging_secondaries
      illustrations_section
      evidence_section
      comments_section
    end
  end

  private

  def expansion_header
    div(class: "flex items-center gap-2 mb-3") do
      span(class: "text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide") do
        "#{@level[:level_code]} · #{@level[:level_title]}"
      end
    end
  end

  # Sentence-first layout: the expectation text flows naturally into
  # the rating pill so the line reads ("Breaks down problems… Most of
  # the time"). The pill itself carries the rating's interaction.
  def expectation_sentence
    return unless @cell_data[:expectation]

    div(class: "mb-3 text-sm text-gray-700 dark:text-gray-300") do
      span { @cell_data[:expectation].description.to_s.strip }
      # Rating controllers replace `#rating-<stable>-<ord>` after every
      # POST — the wrapper id has to live on the same element that
      # `Assessments::TurboStreamHelpers#rating_wrapper_html` renders
      # on the post-rate turbo_stream, otherwise the replace target
      # never matches and the pill goes stale.
      span(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "ml-2 inline-block") do
        render Views::Assessments::FrequencyPill.new(
          capability_stable_id: @capability_stable_id,
          level_ordinal: @ordinal,
          current_frequency: primary_frequency,
          assessment_id: @assessment_id,
          context: @context,
          category_id: @category_id,
          interactive: !primary_perspective_frozen?
        )
      end
    end
  end

  # Renders ONLY perspectives that diverge from the primary AND that the
  # viewer is permitted to see. Permission is enforced upstream — the
  # data builder scrubs manager/aligned data when context == :self —
  # so secondaries are effectively nil for an assessee viewing their
  # own assessment and never reach the render branch.
  # Always renders the wrapper, even when no perspectives diverge —
  # rating controllers replace this target on every POST so the
  # divergent set can grow / shrink as the primary value changes.
  # The wrapper carries `mb-3 space-y-1` even when empty to keep the
  # layout rhythm consistent (avoids the rest of the panel jumping
  # 12 px when a secondary appears).
  def diverging_secondaries
    div(id: "secondaries-#{@capability_stable_id}-#{@ordinal}",
        class: "mb-3 space-y-1") do
      diverging_entries.each do |entry|
        render Views::Assessments::SecondaryRatingLine.new(
          label: entry[:label],
          frequency: entry[:frequency],
          primary_frequency: primary_frequency
        )
      end
    end
  end

  def diverging_entries
    visible_secondary_entries.reject do |entry|
      entry[:frequency].blank? || entry[:frequency] == primary_frequency
    end
  end

  def illustrations_section
    illustrations = @cell_data[:illustrations] || []
    return if illustrations.empty?

    div(class: "mb-3") do
      h4(class: "text-[10px] font-semibold text-gray-500 dark:text-gray-400 " \
                "uppercase tracking-wide mb-1") { "Examples" }
      ul(class: "space-y-1") do
        illustrations.each do |ill|
          li(class: "flex items-start gap-1.5 text-xs text-gray-600 dark:text-gray-400") do
            span(class: "mt-1 w-1 h-1 rounded-full bg-gray-400 dark:bg-gray-500 shrink-0") { }
            span { ill.description }
          end
        end
      end
    end
  end

  def evidence_section
    evidence = @cell_data[:evidence] || []
    return unless @viewer_person_id && (evidence.any? || @can_create_evidence)

    div(class: "mb-3") do
      render Views::Assessments::Evidence::List.new(
        items: evidence,
        assessment_id: @assessment_id,
        viewer_person_id: @viewer_person_id,
        can_create: @can_create_evidence,
        can_relink_others: @can_relink_others_evidence,
        capability_stable_id: @capability_stable_id,
        level_ordinal: @ordinal
      )
    end
  end

  def comments_section
    comments = @cell_data[:comments] || []
    return unless @viewer_person_id && (comments.any? || @can_comment)

    render Views::Assessments::Comments::Thread.new(
      comments: comments,
      assessment_id: @assessment_id,
      viewer_person_id: @viewer_person_id,
      can_create: @can_comment,
      tenant_admin: @viewer_is_tenant_admin,
      capability_stable_id: @capability_stable_id,
      level_ordinal: @ordinal
    )
  end

  def primary_perspective_frozen?
    @context == :alignment ? @alignment_locked : @frozen
  end

  def primary_frequency
    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  # Secondary perspectives the current viewer is permitted to see. Self
  # context has no visible secondaries — the assessee never sees the
  # manager's rating until alignment opens (the data layer already
  # nils manager/aligned data for :self, this just makes the intent
  # explicit). Manager context shows self; alignment shows both.
  def visible_secondary_entries
    case @context
    when :manager
      [ { label: "Self", frequency: @cell_data[:current_frequency] } ]
    when :alignment
      [
        { label: "Self", frequency: @cell_data[:current_frequency] },
        { label: "Manager", frequency: @cell_data[:manager_frequency] }
      ]
    else []
    end
  end
end
