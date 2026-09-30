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
             "font-semibold tracking-wide bg-gray-100 dark:bg-gray-800 " \
             "text-gray-600 dark:text-gray-300"
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

  # The record's status pill, or — while a lens is on — the line saying what
  # the page is read against and how to get back.
  def render_status_or_lens_banner(assessee_name: nil, **pill)
    lens = @matrix_data[:lens]
    if lens && !lens.home?
      render Views::Assessments::LensBanner.new(lens: lens, assessment_id: @assignment.id,
                                                assessee_name: assessee_name)
    else
      render_status_pill(**pill)
    end
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

  def render_status_pill(participant_status:, has_open_cycle:, current_level_complete: false)
    render Views::Assessments::StatusPill.new(
      participant_status: participant_status,
      has_open_cycle: has_open_cycle,
      current_level_complete: current_level_complete
    )
  end
end
