# frozen_string_literal: true

require "test_helper"

# The radar draws whatever CapabilityShape holds: a segment per category, a
# spoke per capability, a ring per level above the first.
class Views::Assessments::CapabilityRadarTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)

  def shape(groups, levels:, person_level:, statuses: {}, required: [])
    categories = groups.map do |category_name, caps|
      { category: CATEGORY.new(category_id: "cat-#{category_name}", name: category_name),
        person_level: person_level,
        capabilities: caps.keys.map do |name|
          { capability: CAP.new(stable_id: "cap-#{name}", name: name),
            cells: { person_level => { current_frequency: "consistent" } } }
        end }
    end
    scores = groups.values.reduce({}, :merge).to_h do |name, score|
      [ "cap-#{name}", { score: score, scorable: true, required: required.include?(name) } ]
    end
    Assessments::CapabilityShape.new(
      categories: categories, merged_levels: levels, person_level: person_level, context: :self,
      scoring: { capability_scores: scores, capability_statuses: statuses }
    )
  end

  def render_radar(shape, size: :detailed)
    Nokogiri::HTML5.fragment(Views::Assessments::CapabilityRadar.new(shape: shape, size: size).call)
  end

  E1_TO_E5 = (1..5).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze

  context "its structure" do
    should "draw a segment per category, a spoke per capability and a ring per level above the first" do
      radar = render_radar(shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 1.2 },
                                   "People" => { "Mentoring" => 1.0 } },
                                 levels: E1_TO_E5, person_level: 3))

      assert_equal 2, radar.css("[data-radar-segment]").size
      assert_equal 3, radar.css("[data-radar-spoke]").size
      assert_equal %w[E2 E3 E4 E5], radar.css("[data-radar-ring]").map { |r| r["data-radar-ring"] }
      assert_equal "E3", radar.at_css("[data-radar-ring-role='assessed']")["data-radar-ring"]
      assert_equal "E4", radar.at_css("[data-radar-ring-role='next']")["data-radar-ring"]
    end
  end

  context "its spokes" do
    setup do
      @shape = shape({ "Craft" => { "Delivery" => 1.5 }, "People" => { "Mentoring" => 1.0 } },
                     levels: E1_TO_E5, person_level: 3)
    end

    should "each link to its capability's card at the assessed level, named for what it shows" do
      link = render_radar(@shape).at_css("a[href='#cell-cap-Delivery-3']")

      assert link, "expected the Delivery spoke to link to its E3 cell"
      assert_equal "1. Delivery, E3 + 50% to E4. Open the capability", link["aria-label"]
      assert_equal "1", link.at_css("text").text
    end

    should "mark a Required capability that blocks the score with a sign, not just a colour" do
      held = shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 1.25 } }, levels: E1_TO_E5, person_level: 3,
                   statuses: { "cap-Quality" => :blocked }, required: [ "Quality" ])
      radar = render_radar(held)
      quality = radar.at_css("a[href='#cell-cap-Quality-3']")

      assert_equal "!", quality.at_css("[data-radar-blocked] text").text
      assert_includes quality["aria-label"], "Required, blocks the score"
      assert_nil radar.at_css("a[href='#cell-cap-Delivery-3'] [data-radar-blocked]")
    end

    should "be a picture in the compact radar, with no links of its own" do
      compact = render_radar(@shape, size: :compact)

      assert_empty compact.css("a")
      assert_equal "true", compact.at_css("svg")["aria-hidden"]
    end
  end
end
