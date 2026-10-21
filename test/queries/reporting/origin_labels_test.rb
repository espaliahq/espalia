# frozen_string_literal: true

require "test_helper"

class Reporting::OriginLabelsTest < ActiveSupport::TestCase
  context ".key_for" do
    should "read nil and blank as GrowthOS" do
      assert_equal "growthos", Reporting::OriginLabels.key_for(nil)
      assert_equal "growthos", Reporting::OriginLabels.key_for("  ")
    end

    should "normalise a system slug" do
      assert_equal "chip", Reporting::OriginLabels.key_for(" Chip ")
    end

    should "treat hyphens and underscores as the same system" do
      assert_equal "hr_portal", Reporting::OriginLabels.key_for("hr-portal")
    end
  end

  context ".label" do
    should "name the systems it knows" do
      assert_equal "GrowthOS", Reporting::OriginLabels.label(nil)
      assert_equal "Slack", Reporting::OriginLabels.label("slack")
      assert_equal "Chip", Reporting::OriginLabels.label("chip")
      assert_equal "GitHub", Reporting::OriginLabels.label("github")
      assert_equal "GrowthOS", Reporting::OriginLabels.label("growthos")
    end

    should "titleise a slug it does not know" do
      assert_equal "Hr Portal", Reporting::OriginLabels.label("hr_portal")
    end
  end
end
