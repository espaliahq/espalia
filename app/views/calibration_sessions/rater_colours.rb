# frozen_string_literal: true

# The rater identity palette, shared by every calibration surface that
# colours a mark by WHO rated (the divergence board's rater-mean dots, the
# cohort view's person dots). One source so a rater can never wear two
# colours on one page.
#
# The eight category hues as solid marks (theme/categorical.css). The first
# three are purple, cyan and pink, the hues no rating uses, because a rater
# dot sits beside rating-coloured marks on the drill-in; the rest keep
# neighbours far apart on the wheel. Initials on every dot remain the
# identity signal of record.
module Views::CalibrationSessions::RaterColours
  RATER_MARKS = %w[
    mark-category-4 mark-category-6 mark-category-7 mark-category-8
    mark-category-2 mark-category-3 mark-category-5 mark-category-1
  ].freeze

  RATER_DOT_CLASSES = RATER_MARKS.map { |mark| "#{mark} bg-mark" }.freeze

  # A rater's OUTLINED marks (a drill-in dot with no evidence behind it)
  RATER_BORDER_CLASSES = RATER_MARKS.map { |mark| "#{mark} border-mark" }.freeze

  # A mark whose rater is not in the session (Score by cohort, the drill-in).
  NOT_IN_SESSION_FILL = "mark-rater-outside bg-mark"
  NOT_IN_SESSION_BORDER = "mark-rater-outside border-mark"

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

  # @param _index [Integer]
  # @return [String] text classes that clear AA on {#rater_dot_class}
  def rater_text_class(_index = nil)
    "text-on-mark"
  end

  # Two letters, uppercased — the shared identity mark on every rater/
  # person disc (tendency strip, divergence board, cohort dots).
  def initials(name)
    name.to_s.split.map(&:first).first(2).join.upcase
  end
end
