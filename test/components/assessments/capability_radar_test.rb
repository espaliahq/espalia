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

  def render_radar(shape, size: :detailed, **options)
    Nokogiri::HTML5.fragment(Views::Assessments::CapabilityRadar.new(shape: shape, size: size, **options).call)
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
      assert radar.at_css("[data-radar-ring-role='next']")["stroke-dasharray"], "expected the next ring dashed"
      assert_nil radar.at_css("[data-radar-ring-role='assessed']")["stroke-dasharray"]
    end

    should "label each ring above the first up the top spoke, naming the assessed and next levels" do
      radar = render_radar(shape({ "Craft" => { "Delivery" => 1.5 } }, levels: E1_TO_E5, person_level: 3))

      assert_equal [ "E2", "E3 · you", "E4 · next", "E5" ], radar.css("[data-radar-ring-label]").map(&:text)
    end

    should "call the assessed ring the person's level, not yours, on someone else's map" do
      radar = render_radar(shape({ "Craft" => { "Delivery" => 1.5 } }, levels: E1_TO_E5, person_level: 3),
                           assessed_as: "assessed")

      assert_includes radar.css("[data-radar-ring-label]").map(&:text), "E3 · assessed"
    end

    should "leave the compact radar's rings unlabelled" do
      radar = render_radar(shape({ "Craft" => { "Delivery" => 1.5 } }, levels: E1_TO_E5, person_level: 3),
                           size: :compact)

      assert_empty radar.css("[data-radar-ring-label]")
    end

    should "fill the whole circle for a framework with one category" do
      radar = render_radar(shape({ "Craft" => { "Delivery" => 1.0, "Quality" => 1.0 } },
                                 levels: E1_TO_E5, person_level: 3))

      assert_equal "circle", radar.at_css("[data-radar-segment]").name
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

    should "mark a capability that blocks the score with a sign, not just a colour" do
      held = shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 1.25 } }, levels: E1_TO_E5, person_level: 3,
                   statuses: { "cap-Quality" => :blocked }, required: [ "Quality" ])
      radar = render_radar(held)
      quality = radar.at_css("a[href='#cell-cap-Quality-3']")

      assert_equal "!", quality.at_css("[data-radar-blocked] text").text
      assert_equal "2. Quality, E3 + 25% to E4. Required, blocks the score. Open the capability", quality["aria-label"]
      assert_nil radar.at_css("a[href='#cell-cap-Delivery-3'] [data-radar-blocked]")
    end

    should "mark a blocking capability still unrated at the assessed level, near the centre" do
      held = Assessments::CapabilityShape.new(
        categories: [ { category: CATEGORY.new(category_id: "cat-Craft", name: "Craft"), person_level: 3,
                        capabilities: [ { capability: CAP.new(stable_id: "cap-Quality", name: "Quality"),
                                          cells: { 3 => { current_frequency: nil } } } ] } ],
        merged_levels: E1_TO_E5, person_level: 3, context: :self,
        scoring: { capability_scores: { "cap-Quality" => { score: 0.0, scorable: true, required: false } },
                   capability_statuses: { "cap-Quality" => :blocked } }
      )

      [ :detailed, :compact ].each do |size|
        assert render_radar(held, size: size).at_css("[data-radar-blocked]"), "expected a #{size} blocked marker"
      end
    end

    should "keep the signs of blocking capabilities stuck at the first level apart, each on its own spoke" do
      names = (1..18).map { |n| "Cap #{n}" }
      held = shape({ "Craft" => names.to_h { |n| [ n, 0.0 ] } }, levels: E1_TO_E5, person_level: 2,
                   statuses: names.to_h { |n| [ "cap-#{n}", :blocked ] })

      [ :detailed, :compact ].each do |size|
        signs = render_radar(held, size: size).css("[data-radar-blocked]").map do |g|
          g["transform"][/translate\((.+)\)/, 1].split.map(&:to_f)
        end
        width = size == :compact ? 12 : 16
        overlapping = signs.combination(2).select do |(ax, ay), (bx, by)|
          (ax - bx).abs < width && (ay - by).abs < width
        end

        assert_equal 18, signs.size
        assert_empty overlapping, "expected no #{size} signs' squares to overlap"
      end
    end

    should "not call a blocking capability Required when its binding isn't" do
      held = shape({ "Craft" => { "Quality" => 0.75 } }, levels: E1_TO_E5, person_level: 3,
                   statuses: { "cap-Quality" => :blocked })

      assert_equal "1. Quality, E2 + 75% to E3. Blocks the score. Open the capability",
                   render_radar(held).at_css("a[href='#cell-cap-Quality-3']")["aria-label"]
    end

    should "be a picture in the compact radar, with no links of its own" do
      compact = render_radar(@shape, size: :compact)

      assert_empty compact.css("a")
      assert_equal "true", compact.at_css("svg")["aria-hidden"]
    end
  end
end
