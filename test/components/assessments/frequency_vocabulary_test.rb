# frozen_string_literal: true

require "test_helper"

# The bottom of the frequency scale reads "Not yet" on every surface —
# never "None" or "Never" (issue #391). The domain value stays `none`;
# only the words people see change. Each surface that derives its copy
# from the palette is pinned here so a relabel can't half-land. (The
# activity feed's case lives in activity/entry_test.rb, next to its
# Entry builder.)
class Views::Assessments::FrequencyVocabularyTest < ActiveSupport::TestCase
  Palette = Views::Assessments::FrequencyPalette

  context "FrequencyPalette" do
    should "label and phrase the none rating as Not yet" do
      assert_equal "Not yet", Palette.label_for("none")
      assert_equal "Not yet", Palette.phrase_for("none")
    end

    should "compose the none rating after a verb without inverting it" do
      assert_equal "not yet demonstrated", Palette.spoken_for("none")
      assert_equal "most of the time", Palette.spoken_for("occasional")
    end
  end

  context "frozen FrequencyPill" do
    should "read Not yet" do
      html = Views::Assessments::FrequencyPill.new(
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2,
        current_frequency: "none", assessment_id: SecureRandom.uuid_v7,
        interactive: false
      ).call
      assert_includes html, "Not yet"
    end
  end

  context "LevelChip" do
    should "describe a none rating as rated not yet demonstrated" do
      html = Views::Assessments::LevelChip.new(
        cell_data: { current_frequency: "none" },
        capability_stable_id: SecureRandom.uuid_v7, ordinal: 2, person_level: 2,
        level_code: "E2"
      ).call
      assert_includes html, "rated not yet demonstrated"
    end
  end

  context "SecondaryRatingLine" do
    should "phrase a divergent none rating as Not yet" do
      html = Views::Assessments::SecondaryRatingLine.new(
        label: "Self", frequency: "none", primary_frequency: "consistent"
      ).call
      assert_includes html, "Not yet"
    end
  end
end
