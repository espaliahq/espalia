# frozen_string_literal: true

require "test_helper"

# The wording is the point of this module: one source, so the strip, the
# board and the drill-in can't drift apart. These pin the contract every
# calibration view leans on.
class Views::CalibrationSessions::GlossaryTest < ActiveSupport::TestCase
  TERMS = Views::CalibrationSessions::Glossary::TERMS

  should "define every term the calibration surfaces render" do
    # Each key is rendered by a view today; dropping one silently would
    # raise KeyError at render, so pin the set here where it's cheap.
    expected = %i[
      org_mean reports org_delta distribution self_gap evidence carried
      spread raters_disagree backing to_confirm
    ]

    assert_equal expected.sort, TERMS.keys.sort
  end

  should "give every term a label and a definition that says something" do
    TERMS.each do |key, term|
      assert term[:label].present?, "#{key} has no label"
      assert term[:definition].to_s.length > 40,
        "#{key}'s definition is too short to define anything"
    end
  end

  should "state the denominators the numbers actually use" do
    # These two are the ones a facilitator most often reads wrong, and both
    # were only written down in a YARD comment until now.
    assert_match(/both sides rated/, TERMS[:self_gap][:definition],
                 "a cell the report never self-rated has no gap to average")
    assert_match(/assessed level/, TERMS[:org_mean][:definition],
                 "the org mean pools at-level cells, not rater means")
  end

  should "describe carried ratings as real ratings" do
    # The house rule: marking never softens. A definition that implied a
    # carried value doesn't count would contradict the surfaces it explains.
    definition = TERMS[:carried][:definition]

    assert_match(/still/, definition)
    assert_no_match(/ignore|don't count|do not count/i, definition)
  end
end
