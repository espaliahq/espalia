# frozen_string_literal: true

require "test_helper"

# The card's avatar: a blade per capability, clockwise from the top, whose
# length is the level it has reached, around a dashed circle at the assessed
# level met.
class Views::Assessments::CapabilityBladesTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)

  E1_TO_E5 = (1..5).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze

  # @param groups [Hash{String => Hash{String => Float}}] category name =>
  #   capability name => score on the hero's scale
  def shape(groups, unrated: [], levels: E1_TO_E5, person_level: 3)
    categories = groups.map do |category_name, caps|
      { category: CATEGORY.new(category_id: "cat-#{category_name}", name: category_name),
        person_level: person_level,
        capabilities: caps.keys.map do |name|
          { capability: CAP.new(stable_id: "cap-#{name}", name: name),
            cells: { person_level => { current_frequency: ("consistent" unless unrated.include?(name)) } } }
        end }
    end
    scores = groups.values.reduce({}, :merge).to_h { |name, score| [ "cap-#{name}", { score: score, scorable: true } ] }
    Assessments::CapabilityShape.new(categories: categories, merged_levels: levels, person_level: person_level,
                                     context: :self,
                                     scoring: { capability_scores: scores, capability_statuses: {} })
  end

  def render_blades(shape)
    Nokogiri::HTML5.fragment(Views::Assessments::CapabilityBlades.new(shape: shape).call)
  end

  # One blade past E3, one short of it and one on it, across two categories.
  def team_lead
    shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 0.5 }, "People" => { "Mentoring" => 1.0 } })
  end

  # A blade's wedge as its radius and the angles its arc runs between, in
  # degrees clockwise from twelve o'clock.
  def wedge(avatar, number) = wedge_through(avatar.at_css("[data-blade='#{number}']"))

  def wedge_through(path)
    numbers = path["d"].scan(/-?\d+(?:\.\d+)?/).map(&:to_f)
    x0, y0, radius = numbers[2..4]
    x1, y1 = numbers.last(2)
    clock = ->(x, y) { ((Math.atan2(y, x) * 180 / Math::PI) + 90).round(1) % 360 }
    { radius: radius, from: clock.(x0, y0), to: clock.(x1, y1) }
  end

  context "its blades" do
    should "start the first at twelve o'clock and run clockwise, each touching the next" do
      avatar = render_blades(team_lead)

      assert_equal [ [ 0.0, 120.0 ], [ 120.0, 240.0 ], [ 240.0, 0.0 ] ],
                   (1..3).map { |n| wedge(avatar, n).values_at(:from, :to) }
      assert_empty avatar.css("line"), "expected no lines between the blades"
    end

    should "reach the dashed circle at the assessed level met, past it when ahead and inside it when short" do
      avatar = render_blades(team_lead)
      met = avatar.at_css("[data-blades-met]")

      assert_equal 20.0, met["r"].to_f, "expected E3 met two thirds out, between none of it and 150% of it"
      assert met["stroke-dasharray"], "expected the met circle dashed"
      assert_equal [ 30.0, 10.0, 20.0 ], (1..3).map { |n| wedge(avatar, n)[:radius] }
    end

    should "measure from none of the assessed level whatever the ladder, holding a capability far ahead at the rim" do
      first = shape({ "Craft" => { "Delivery" => 0.75, "Quality" => 3.0 } }, levels: E1_TO_E5.first(1), person_level: 1)
      avatar = render_blades(first)

      assert_equal 20.0, avatar.at_css("[data-blades-met]")["r"].to_f
      assert_equal [ 15.0, 20.0 ], (1..2).map { |n| wedge(avatar, n)[:radius] },
                   "expected 75% of E1 at half the radius and E1 held at met, the top of a one-level ladder"
    end

    should "fade only the blades short of the assessed level" do
      avatar = render_blades(team_lead)

      assert_equal [ [ "1", nil ], [ "2", "0.8" ], [ "3", nil ] ],
                   avatar.css("[data-blade]").map { |blade| [ blade["data-blade"], blade["fill-opacity"] ] }
    end

    should "colour each blade by its category" do
      avatar = render_blades(team_lead)
      fill = ->(n) { avatar.at_css("[data-blade='#{n}']")["class"][/fill-\(--gos-category-\d+-strong\)/] }

      assert_equal fill.(1), fill.(2)
      assert_not_equal fill.(1), fill.(3)
    end

    should "tint each category's slots as one wedge, so no seam shows inside it" do
      tints = render_blades(team_lead).css("[data-blades-category]").map do |tint|
        [ tint["data-blades-category"], wedge_through(tint).values_at(:from, :to) ]
      end

      assert_equal [ [ "Craft", [ 0.0, 240.0 ] ], [ "People", [ 240.0, 0.0 ] ] ], tints
    end

    should "leave an unrated capability's slot empty" do
      avatar = render_blades(shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 0.5, "Testing" => 1.0 } },
                                   unrated: [ "Quality" ]))

      assert_equal %w[1 3], avatar.css("[data-blade]").map { |blade| blade["data-blade"] }
    end
  end

  context "what it says" do
    should "name how many capabilities are met at the assessed level, once" do
      avatar = render_blades(team_lead)
      picture = avatar.at_css("svg")

      assert_equal "img", picture["role"]
      assert_equal "2 of 3 capabilities met at E3", picture["aria-label"]
      assert_equal "2 of 3 met at E3", avatar.at_css("[data-blades-caption]").text.squish
      assert_equal "true", avatar.at_css("[data-blades-caption]")["aria-hidden"]
    end

    should "offer nothing to click or focus" do
      avatar = render_blades(team_lead)

      assert_empty avatar.css("a, button, [tabindex]")
    end
  end
end
