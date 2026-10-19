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

  # Same hues, same order, for a rater's OUTLINED marks (a drill-in dot
  # with no evidence behind it).
  RATER_BORDER_CLASSES = %w[
    border-teal-600 dark:border-teal-400
    border-purple-600 dark:border-purple-400
    border-orange-600 dark:border-orange-400
    border-pink-600 dark:border-pink-400
    border-indigo-600 dark:border-indigo-400
    border-cyan-600 dark:border-cyan-400
  ].each_slice(2).map { |light, dark| "#{light} #{dark}" }.freeze

  # Initials on a SOLID rater fill. White misses 4.5:1 on the light teal,
  # orange and cyan (3.6–3.7:1), so those take near-black; every dark-theme
  # fill is light enough for gray-900.
  RATER_TEXT_CLASSES = %w[
    text-gray-950 text-white text-gray-950 text-white text-white text-gray-950
  ].map { |light| "#{light} dark:text-gray-900" }.freeze

  # A mark whose rater is not in the session (Score by cohort, the drill-in).
  NOT_IN_SESSION_FILL = "bg-gray-500 dark:bg-gray-400"
  NOT_IN_SESSION_BORDER = "border-gray-500 dark:border-gray-400"

  # @param index [Integer] the rater's position in the session's rater list
  # @return [String] background classes for both themes
  def rater_dot_class(index)
    RATER_DOT_CLASSES[index % RATER_DOT_CLASSES.size]
  end

  # @param index [Integer]
  # @return [String] border classes for both themes
  def rater_border_class(index)
    RATER_BORDER_CLASSES[index % RATER_BORDER_CLASSES.size]
  end

  # @param index [Integer]
  # @return [String] text classes that clear AA on {#rater_dot_class}
  def rater_text_class(index)
    RATER_TEXT_CLASSES[index % RATER_TEXT_CLASSES.size]
  end
  # Two letters, uppercased — the shared identity mark on every rater/
  # person disc (tendency strip, divergence board, cohort dots).
  def initials(name)
    name.to_s.split.map(&:first).first(2).join.upcase
  end
end
