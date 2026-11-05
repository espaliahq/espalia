# frozen_string_literal: true

# Shared chrome (shortcode chip + status pill) for the self-assessment and
# manager-review header rows. Kept in one place so the two views never drift
# on chip styling or status badge variants.
module Views::Assessments::HeaderChrome
  private

  # The params naming the lens the page is read against, carried on every
  # frame `src` so a frame reload — a broadcast after a rating included —
  # reads the same role and level as the page around it.
  #
  # @return [Hash]
  def lens_params
    @matrix_data[:lens]&.to_params || {}
  end

  def render_shortcode_chip(role:, level:)
    span(
      class: "inline-flex items-center px-1.5 py-0.5 rounded font-mono text-xs " \
             "font-semibold tracking-wide bg-neutral-subtle " \
             "text-muted"
    ) { "#{role.code}#{level.ordinal}" }
  end

  # The shortcode chip, doubling as the lens control. Falls back to the plain
  # chip for a matrix built without a lens.
  #
  # @param assessee_name [String, nil] nil on the assessee's own page
  def render_lens_control(assessee_name: nil)
    lens = @matrix_data[:lens]
    return render_shortcode_chip(role: @matrix_data[:role], level: @matrix_data[:level]) unless lens

    render Views::Assessments::LensControl.new(lens: lens, assessment_id: @assignment.id,
                                               whose: lens_whose(assessee_name))
  end

  # The record's status pill — withheld while a lens is on, where the lens
  # banner takes its place (the pill describes the record's lifecycle, which
  # a lens neither reads nor changes), and on a past cycle, where the past
  # cycle banner does.
  def render_status_pill_unless_lens(**pill)
    render_status_pill(**pill) unless off_record_lens || past_cycle_lens
  end

  # Every cycle the person joined, so a past one is a click away.
  def render_cycle_control
    lens = @matrix_data[:lens]
    return unless lens

    render Views::Assessments::CycleControl.new(lens: lens, cycles: @cycles, assessment_id: @assignment.id)
  end

  # Which past cycle the page reads, how it ended, and the way back.
  def render_past_cycle_banner
    lens = past_cycle_lens
    return unless lens

    render Views::Assessments::PastCycleBanner.new(lens: lens, assessment_id: @assignment.id,
                                                   has_open_cycle: @cycles.any? { |entry| open_entry?(entry) })
  end

  def past_cycle_lens
    lens = @matrix_data[:lens]
    lens if lens&.past?
  end

  def open_entry?(entry)
    entry.cycle.status == "open" && entry.enrollment.status != "withdrawn"
  end

  # The line saying what the page is read against and how to get back, on
  # its own row under the header so it never pushes the header's actions
  # out of line.
  def render_lens_banner(assessee_name: nil, can_start_alignment: false, viewer: nil)
    lens = off_record_lens
    return unless lens

    render Views::Assessments::LensBanner.new(
      lens: lens, assessment_id: @assignment.id, assessee_name: assessee_name,
      alignment: (@matrix_data[:lens_alignment] unless lens.home_role?),
      can_start_alignment: can_start_alignment, viewer: viewer,
      exploration: @exploration, can_explore: @can_explore, viewer_person_id: @viewer_person_id
    )
  end

  # The dialogs the banner's exploration buttons open (ADR-22): declaring
  # the lens as an exploration, or stopping the open one.
  #
  # @param assessee_name [String, nil] nil on the assessee's own page
  def render_exploration_modals(assessee_name: nil)
    lens = off_record_lens
    return unless lens && @can_explore

    if @exploration
      other_party = assessee_name.to_s.split.first.presence || "your manager"
      render Views::Assessments::StopExplorationModal.new(lens: lens, exploration: @exploration,
                                                          assessment_id: @assignment.id, other_party: other_party)
    else
      render Views::Assessments::StartExplorationModal.new(lens: lens, assessment_id: @assignment.id,
                                                           assessee_name: assessee_name)
    end
  end

  # "Aligning · PM3" beside the home status, for every other role alignment
  # has started against this cycle (ADR-22). Off the record, the banner says
  # where the lens role stands instead.
  def render_lens_alignment_chips
    return if off_record_lens || past_cycle_lens

    render Views::Assessments::LensAlignmentChips.new(alignments: @matrix_data[:lens_alignments] || [],
                                                      assessment_id: @assignment.id)
  end

  # The confirmation "Start alignment against PM3" opens — mounted only
  # where the banner offers the start.
  def render_start_lens_alignment_modal(assessee_name:, can_start_alignment:)
    lens = off_record_lens
    return unless lens && can_start_alignment

    render Views::Assessments::StartLensAlignmentModal.new(lens: lens, assessment_id: @assignment.id,
                                                           assessee_name: assessee_name)
  end

  def off_record_lens
    lens = @matrix_data[:lens]
    lens unless lens.nil? || lens.home?
  end

  # Mounted with the page's other embedded modals, inside the `modal`
  # controller the chip's "Another role…" item opens it through.
  def render_lens_role_modal(assessee_name: nil)
    lens = @matrix_data[:lens]
    return unless lens

    render Views::Assessments::LensRoleModal.new(lens: lens, assessment_id: @assignment.id,
                                                 whose: lens_whose(assessee_name))
  end

  def lens_whose(assessee_name)
    first = assessee_name.to_s.split.first
    first.present? ? "#{first}'s" : "your"
  end

  def render_status_pill(participant_status:, has_open_cycle:, context:, current_level_complete: false, work: {})
    render Views::Assessments::StatusPill.new(
      participant_status: participant_status,
      has_open_cycle: has_open_cycle,
      context: context,
      current_level_complete: current_level_complete,
      work: work
    )
  end
end
