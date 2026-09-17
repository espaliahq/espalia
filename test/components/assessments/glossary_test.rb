# frozen_string_literal: true

require "test_helper"

# The assessment vocabulary (#414). Every definition has to name this
# viewer's level codes, their framework's bands and their tenant's words —
# copy that says 80% where the framework says 75% is worse than no copy.
class Views::Assessments::GlossaryTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  def glossary(current: "E3", nxt: "E4", second_person: true,
               thresholds: { underperforming: 0.8, meeting: 0.95, mastering: 1.5 })
    Views::Assessments::Glossary.new(
      current_code: current, next_code: nxt, thresholds: thresholds,
      second_person: second_person, tenant: @tenant
    )
  end

  context "naming the reader's own framework" do
    should "use the level codes rather than 'your level'" do
      definition = glossary.definition(:score)

      assert_includes definition, "E3"
      assert_includes definition, "E4"
      assert_not_includes definition, "your level"
    end

    should "quote the framework's configured bands, not the shipped ones" do
      definition = glossary(thresholds: { underperforming: 0.6, meeting: 0.75, mastering: 1.25 })
        .definition(:state)

      assert_includes definition, "60%"
      assert_includes definition, "75%"
      assert_includes definition, "125%"
      assert_not_includes definition, "80%"
    end

    should "use the tenant's own word for a state" do
      ActsAsTenant.with_tenant(@tenant) { @tenant.update!(mastering_label: "Advancing") }

      assert_includes glossary.definition(:state), "Advancing"
    end

    should "say there is nothing above at the top of the ladder" do
      definition = glossary(nxt: nil).definition(:score)

      assert_includes definition, "no level above"
      assert_not_includes definition, "200%"
    end
  end

  context "who is reading" do
    should "address the assessee on their own page" do
      assert_includes glossary.definition(:score), "expects you show"
    end

    should "describe the report on a manager's page" do
      assert_includes glossary(second_person: false).definition(:score), "expects they show"
    end
  end

  context "the copy rules" do
    should "never use a model word" do
      # The reader did not build the engine: "band", "gate", "tolerance",
      # "weight unit", "ratio", "perspective" are ours, not theirs.
      forbidden = %w[band gate tolerance ratio perspective component deficit binding ordinal]

      glossary.keys.each do |key|
        definition = glossary.definition(key).downcase
        forbidden.each do |word|
          assert_not_includes definition, word, "#{key} uses the model word '#{word}'"
        end
      end
    end

    should "say what does not count, since that is what people assume wrongly" do
      assert_includes glossary.definition(:score), "Feedback and comments are not part of it"
      assert_includes glossary.definition(:not_rated), "not a zero"
      assert_includes glossary.definition(:below_levels), "assumed to be met"
      assert_includes glossary.definition(:carried), "confirm or change"
    end

    should "define every term it offers" do
      glossary.keys.each do |key|
        assert glossary.label(key).present?, "#{key} has no label"
        assert_operator glossary.definition(key).length, :>, 40, "#{key}'s definition is too thin"
      end
    end
  end

  context "the shared scale sentence" do
    should "be the one the calibration cohort view reads" do
      # Both surfaces show the same number; only one of them knows a level
      # code, so the level-free sentence is shared rather than retyped.
      assert_includes Views::CalibrationSessions::Glossary::TERMS.dig(:pct_of_expected, :definition),
                      Views::Assessments::Glossary::SCALE_SENTENCE
    end
  end
end
