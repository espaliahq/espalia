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
      org_mean reports org_delta distribution self_gap carried
      spread raters_disagree backing to_confirm
      pct_of_expected cohort_median score_gate
      rated_cells rating_coverage evidence_coverage ready fully_rated
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
    assert_match(/every cell/, TERMS[:evidence_coverage][:definition],
                 "evidence coverage is over all at-level cells, the rating-coverage scale")
  end

  should "give a repeated term a distinct id per instance" do
    # The board renders `spread` once per capability. Without the suffix
    # every one of them claims id="calibration-term-spread", which makes
    # each trigger's aria-describedby ambiguous and the HTML invalid.
    view = Class.new(Views::Base) do
      include Views::CalibrationSessions::Glossary
      def view_template
        defined_term(:spread, suffix: "cap-1")
        defined_term(:spread, suffix: "cap-2")
        defined_term(:self_gap)
      end
    end

    html = view.new.call

    assert_includes html, %(id="calibration-term-spread-cap-1")
    assert_includes html, %(id="calibration-term-spread-cap-2")
    # A term that appears once keeps the short, linkable id.
    assert_includes html, %(id="calibration-term-self-gap")
  end

  should "tie the cohort score to the assessment's own number" do
    assert_match(/own assessment/, TERMS[:pct_of_expected][:definition],
                 "the room and the individual must never argue about arithmetic")
    assert_match(/[Mm]anager ratings only/, TERMS[:pct_of_expected][:definition])
  end

  should "describe carried ratings as real ratings" do
    # The house rule: marking never softens. A definition that implied a
    # carried value doesn't count would contradict the surfaces it explains.
    definition = TERMS[:carried][:definition]

    assert_match(/still/, definition)
    assert_no_match(/ignore|don't count|do not count/i, definition)
  end
end
