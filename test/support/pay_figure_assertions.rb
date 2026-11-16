# frozen_string_literal: true

# Checks for a pay figure in what a read returns, with every id taken out
# first: a random UUID or a 64-character digest can hold any five digits,
# and one person id once held 92417
# ([PR #436](https://github.com/espaliahq/espalia/pull/436)).
#
# Each id becomes "<id>" rather than nothing, so digits on either side of it
# can't join into a figure that was never there. A figure written beside an
# id still counts.
module PayFigureAssertions
  OPAQUE_ID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|(?<!\h)\h{64}(?!\h)/

  # @param output [String, #to_json] a read's payload, rendered HTML, a log
  # @return [String] the output as text, each id replaced with "<id>"
  def self.without_ids(output)
    (output.is_a?(String) ? output : output.to_json).gsub(OPAQUE_ID, "<id>")
  end

  # @param output [String, #to_json]
  # @param figure [String] a pay figure, or a prefix of one
  # @param message [String, nil]
  def assert_pay_figure(output, figure, message = nil)
    assert_includes PayFigureAssertions.without_ids(output), pay_figure!(figure), message
  end

  # @param output [String, #to_json]
  # @param figure [String] a pay figure, or a prefix of one
  # @param message [String, nil]
  def assert_no_pay_figure(output, figure, message = nil)
    assert_not_includes PayFigureAssertions.without_ids(output), pay_figure!(figure), message
  end

  private

  def pay_figure!(figure)
    raise ArgumentError, "a pay figure must be a non-empty string without an id in it" unless figure.is_a?(String) && figure.present? && !figure.match?(OPAQUE_ID) && !figure.include?("<id>")

    figure
  end
end

ActiveSupport::TestCase.include(PayFigureAssertions)
