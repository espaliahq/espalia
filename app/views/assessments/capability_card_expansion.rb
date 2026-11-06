# frozen_string_literal: true

# Expansion panel below the level strip when a level chip is focused.
#
# Shows expectation text, the inline FrequencyPill (interactive, or a
# static pill when frozen/locked), divergent SecondaryRatingLines,
# illustrations, evidence, and comments for the focused capability ×
# level cell.
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
  # @param lens [Assessments::Lens, nil] the role and level the page is read
  #   against; its params ride the pill's and the comments' forms so the
  #   response re-renders through it
  def initialize(cell_data:, capability:, level:, capability_stable_id:,
                 ordinal:, person_level:, assessment_id:, context: :self,
                 category_id: nil, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false, lens: nil)
    @lens = lens
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
    @can_request_evidence = can_request_evidence
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
      class: "mt-3 pt-3 border-t border-default"
    ) do
      expansion_header
      expectation_sentence
      illustrations_section
      evidence_section
      comments_section
    end
  end

  # The cell's comment thread, unrendered, so a comment's response can swap
  # just the thread ([#625](https://github.com/mr-yum/growth-os/issues/625)).
  #
  # @param focus [String, nil] what the thread focuses on connect, after the
  #   viewer's own write (see Comments::Thread)
  # @return [Views::Assessments::Comments::Thread, nil] nil when the viewer
  #   neither sees comments here nor can add one
  def comments_thread(focus: nil)
    comments = @cell_data[:comments] || []
    return unless @viewer_person_id && (comments.any? || @can_comment)

    Views::Assessments::Comments::Thread.new(
      comments: comments,
      assessment_id: @assessment_id,
      viewer_person_id: @viewer_person_id,
      can_create: @can_comment,
      tenant_admin: @viewer_is_tenant_admin,
      capability_stable_id: @capability_stable_id,
      level_ordinal: @ordinal,
      lens_params: @lens&.to_params || {},
      focus: focus,
      read_only: @lens&.past? || false
    )
  end

  private

  def expansion_header
    div(class: "flex items-center gap-2 mb-3") do
      span(class: "text-xs font-medium text-muted uppercase tracking-wide") do
        "#{@level[:level_code]} · #{@level[:level_title]}"
      end
    end
  end

  # Sentence-first layout. The expectation flows into:
  #   "<text>. Demonstrates: [pill]    <divergent secondaries>"
  # All on one line; on narrow viewports the secondaries wrap below
  # the pill via flex-wrap. The lead-in "Demonstrates:" shares a wrapping
  # inline-flex box with the pill, so a line break takes both together
  # and, where even the pair is wider than the line (a 320px phone), the
  # pill drops under its label instead of pushing the page sideways.
  def expectation_sentence
    return unless @cell_data[:expectation]

    div(class: "mb-3 text-sm text-muted") do
      span { @cell_data[:expectation].description.to_s.strip }
      # `mr-3` is a sentence-pause's worth of gap — enough to set the
      # pill apart from the secondary without feeling disconnected.
      # Living on the pill wrapper (not as `ml-*` on the secondary)
      # means the trailing margin sits at the end of the pill's line
      # when the secondary wraps below on mobile, so the secondary
      # starts flush against the new line's left edge.
      span(class: "inline-flex flex-wrap items-baseline gap-x-1 ml-2 mr-3") do
        span(class: "text-muted") { "Demonstrates:" }
        # Rating controllers replace `#rating-<stable>-<ord>` after every
        # POST — the id has to live on the element
        # `Assessments::TurboStreamHelpers#rating_wrapper_html` writes.
        span(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "inline-block") do
          render Views::Assessments::FrequencyPill.new(
            capability_stable_id: @capability_stable_id,
            level_ordinal: @ordinal,
            current_frequency: primary_frequency,
            assessment_id: @assessment_id,
            context: @context,
            category_id: @category_id,
            interactive: !primary_perspective_frozen?,
            carried: primary_carried?,
            lens_params: @lens&.to_params || {},
            static_title: frozen_title
          )
        end
      end
      diverging_secondaries
    end
  end

  # Inline `<span>` so the secondaries flow with the sentence rather
  # than dropping to a separate row. Always renders the wrapper (even
  # empty) so rating controllers `turbo_stream.replace` the target on
  # every POST and the divergent set can grow / shrink as the primary
  # value changes.
  def diverging_secondaries
    span(id: "secondaries-#{@capability_stable_id}-#{@ordinal}",
         class: "inline-flex flex-wrap items-center gap-4") do
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
      h4(class: "text-[10px] font-semibold text-muted " \
                "uppercase tracking-wide mb-1") { "Examples" }
      ul(class: "space-y-1") do
        illustrations.each do |ill|
          li(class: "flex items-start gap-1.5 text-xs text-muted") do
            span(class: "mt-1 w-1 h-1 rounded-full bg-current text-subtle shrink-0") { }
            span { ill.description }
          end
        end
      end
    end
  end

  def evidence_section
    evidence = @cell_data[:evidence] || []
    return unless @viewer_person_id && (evidence.any? || @can_create_evidence || @can_request_evidence)

    div(class: "mb-3") do
      render Views::Assessments::Evidence::List.new(
        items: evidence,
        assessment_id: @assessment_id,
        viewer_person_id: @viewer_person_id,
        can_create: @can_create_evidence,
        can_request: @can_request_evidence,
        can_relink_others: @can_relink_others_evidence,
        capability_stable_id: @capability_stable_id,
        level_ordinal: @ordinal,
        read_only: @lens&.past? || false
      )
    end
  end

  def comments_section
    thread = comments_thread
    render thread if thread
  end

  # Freeze is per cell (ADR-22): a self or manager rating freezes once any
  # started alignment reads the cell, whichever lens the page is read
  # through; an agreed value, once no alignment reading it is in progress.
  def primary_perspective_frozen?
    if @context == :alignment
      @alignment_locked || @cell_data[:agreed_locked] || false
    else
      @frozen || !@cell_data[:frozen_by].nil?
    end
  end

  # Why the pill is read-only when another role's conversation froze it —
  # "Frozen — alignment against PM3 has started".
  def frozen_title
    alignment = @cell_data[:frozen_by]
    return unless alignment && @context != :alignment && primary_perspective_frozen?

    "Frozen — alignment against #{alignment.code} has started"
  end

  def primary_frequency
    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  # Whether the primary perspective's value is carried forward (seeded)
  # and not yet confirmed. Aligned values are conversation output — never
  # seeded — so alignment context never renders the carried treatment.
  def primary_carried?
    case @context
    when :self    then @cell_data[:current_frequency_carried] || false
    when :manager then @cell_data[:manager_frequency_carried] || false
    else false
    end
  end

  # Secondary perspectives the current viewer is permitted to see. In self
  # context the builder has already scrubbed manager and aligned values from
  # every cell the disclosure doesn't name (ADR-22), so the assessee sees
  # them only on a shared cell home alignment disclosed, read through a
  # lens. Manager context shows self; alignment shows both.
  def visible_secondary_entries
    case @context
    when :self
      # Only disclosed cells carry these values (the builder scrubs the
      # rest), so before alignment this renders nothing.
      [ { label: "Manager", frequency: @cell_data[:manager_frequency] },
        { label: "Agreed", frequency: @cell_data[:aligned_frequency] } ]
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
