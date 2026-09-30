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

  def render_status_pill(participant_status:, has_open_cycle:, current_level_complete: false)
    render Views::Assessments::StatusPill.new(
      participant_status: participant_status,
      has_open_cycle: has_open_cycle,
      current_level_complete: current_level_complete
    )
  end
end
