# frozen_string_literal: true

require "test_helper"

# The bottom of the frequency scale reads "Not yet" on every surface —
# never "None" or "Never" (issue #391). The domain value stays `none`;
# only the words people see change. Each surface that derives its copy
# from the palette is pinned here so a relabel can't half-land.
class Views::Assessments::FrequencyVocabularyTest < ActiveSupport::TestCase
  Palette = Views::Assessments::FrequencyPalette

  context "FrequencyPalette" do
    should "label and phrase the none rating as Not yet" do
      assert_equal "Not yet", Palette.label_for("none")
      assert_equal "Not yet", Palette.phrase_for("none")
    end

    should "keep the domain value none" do
      assert_equal "none", Palette::ORDERED_KEYS.first
      assert Palette.config_for("none").present?
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
      assert_not_includes html, "Never"
      assert_not_includes html, ">None<"
    end
  end

  context "LevelChip" do
    should "describe a none rating as rated not yet" do
      html = Views::Assessments::LevelChip.new(
        cell_data: { current_frequency: "none" },
        capability_stable_id: SecureRandom.uuid_v7, ordinal: 2, person_level: 2,
        level_code: "E2"
      ).call
      assert_includes html, "rated not yet"
      assert_not_includes html, "rated never"
    end
  end

  context "SecondaryRatingLine" do
    should "phrase a divergent none rating as Not yet" do
      html = Views::Assessments::SecondaryRatingLine.new(
        label: "Self", frequency: "none", primary_frequency: "consistent"
      ).call
      assert_includes html, "Not yet"
      assert_not_includes html, "Never"
    end
  end

  context "activity feed entry" do
    should "label a none rating as Not yet on the secondary line" do
      entry = Assessments::ActivityFeedQuery::Entry.new(
        id: SecureRandom.uuid_v7, kind: "self_rated", occurred_at: nil,
        payload: { frequency: "none" },
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2,
        capability_name: "Critical Thinking"
      )
      html = Views::Assessments::Activity::Entry.new(entry: entry).call
      assert_includes html, "Not yet"
      assert_not_includes html, ">None<"
    end
  end
end
