# frozen_string_literal: true

# The rater identity palette, shared by every calibration surface that
# colours a mark by WHO rated (the divergence board's rater-mean dots, the
# cohort view's person dots). One source so a rater can never wear two
# colours on one page.
#
# ORDER IS LOAD-BEARING: adjacent slots must stay tell-apart-able in BOTH
# themes. With pink beside purple the dark pair (pink-400 / purple-400)
# sat at ΔE 13.3 — below the distinguishability floor for full colour
# vision, let alone CVD. Orange between them lifts the worst dark pair to
# 27.8 (validated with the dataviz palette checker, light and dark).
# Initials on every dot remain the identity signal of record.
module Views::CalibrationSessions::RaterColours
  RATER_DOT_CLASSES = %w[
    bg-teal-600 dark:bg-teal-400
    bg-purple-600 dark:bg-purple-400
    bg-orange-600 dark:bg-orange-400
    bg-pink-600 dark:bg-pink-400
    bg-indigo-600 dark:bg-indigo-400
    bg-cyan-600 dark:bg-cyan-400
  ].each_slice(2).map { |light, dark| "#{light} #{dark}" }.freeze

  # @param index [Integer] the rater's position in the session's rater list
  # @return [String] background classes for both themes
  def rater_dot_class(index)
    RATER_DOT_CLASSES[index % RATER_DOT_CLASSES.size]
  end
end
