# frozen_string_literal: true

require "test_helper"

# The capability radar's data: one point per in-role capability, placed on
# the role's ladder by the capability's own score, so the radar, the card and
# the hero read one number.
class Assessments::CapabilityShapeTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)

  E1_TO_E5 = (1..5).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze

  # @param groups [Hash{String => Hash{String => Float}}] category name =>
  #   capability name => score on the hero's scale
  def shape(groups, levels: E1_TO_E5, person_level: 3, rated: true, statuses: {}, extra: {}, category_scores: {})
    categories = groups.map do |category_name, caps|
      { category: CATEGORY.new(category_id: "cat-#{category_name}", name: category_name),
        person_level: person_level,
        capabilities: caps.keys.map do |name|
          { capability: CAP.new(stable_id: "cap-#{name}", name: name),
            cells: { person_level => { current_frequency: rated_for(rated, name) ? "consistent" : nil } } }
        end }
    end
    capability_scores = groups.values.reduce({}, :merge).to_h do |name, score|
      [ "cap-#{name}", { score: score, scorable: true, required: false }.merge(extra.fetch(name, {})) ]
    end
    scoring = { capability_scores: capability_scores, capability_statuses: statuses,
                category_scores: category_scores }

    Assessments::CapabilityShape.new(categories: categories, scoring: scoring, merged_levels: levels,
                                     person_level: person_level, context: :self)
  end

  def point(shape, name) = shape.points.find { |p| p.name == name }

  def rated_for(rated, name) = rated.is_a?(Hash) ? rated.fetch(name) : rated

  def with_category_score(rated:)
    shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 1.5 } }, rated: rated,
      category_scores: { "cat-Craft" => { score: 1.56, scorable: true } })
  end

  context "a capability's level reached" do
    should "place a score of 160% at E3 as E3 met and 60% of the way to E4" do
      reached = point(shape({ "Craft" => { "Delivery" => 1.6 } }), "Delivery")

      assert_in_delta 2.6, reached.reached, 0.001
      assert_equal "E3 + 60% to E4", reached.label
    end

    should "stop at the top of the ladder, saying the top level is met, for a score that reaches past it" do
      top = point(shape({ "Craft" => { "Delivery" => 3.5 } }), "Delivery")

      assert_in_delta 4.0, top.reached, 0.001
      assert_equal "E5 met", top.label
    end

    should "have no level, and say so, while the viewer has not rated it at the assessed level" do
      unrated = point(shape({ "Craft" => { "Delivery" => 0.0 } }, rated: false), "Delivery")

      assert_nil unrated.reached
      assert_equal "Not rated", unrated.label
    end

    should "have no level, and say so, when the assessed level holds no expectation for it" do
      none = point(shape({ "Craft" => { "Delivery" => 0.0 } }, extra: { "Delivery" => { scorable: false } }),
                   "Delivery")

      assert_nil none.reached
      assert_equal "No expectation at E3", none.label
    end
  end

  context "the categories" do
    should "colour each by position, skipping the rating red, and repeat after seven" do
      many = shape(("A".."I").to_h { |c| [ c, { "#{c} cap" => 1.0 } ] })

      assert_equal %w[A B C D E F G H I], many.groups.map(&:name)
      assert_equal [ 1, 3, 4, 5, 7, 6, 8, 1, 3 ], many.groups.map(&:hue)
    end

    should "number capabilities in framework order across every category" do
      two = shape({ "Craft" => { "Delivery" => 1.0, "Quality" => 1.0 }, "People" => { "Mentoring" => 1.0 } })

      assert_equal [ [ 1, "Delivery" ], [ 2, "Quality" ], [ 3, "Mentoring" ] ],
                   two.groups.flat_map(&:points).map { |p| [ p.number, p.name ] }
    end
  end

  context "a Required capability" do
    should "be marked when its gap blocks the score" do
      held = shape({ "Craft" => { "Quality" => 1.25, "Delivery" => 1.25 } },
                   statuses: { "cap-Quality" => :blocked },
                   extra: { "Quality" => { required: true }, "Delivery" => { required: true } })

      assert point(held, "Quality").blocked
      assert_not point(held, "Delivery").blocked
    end
  end

  context "a category's score" do
    should "show once enough of the category is rated for the chip bar to score it" do
      assert_in_delta 1.56, with_category_score(rated: true).groups.first.score, 0.001
    end

    should "show at exactly half the category rated" do
      half = shape({ "Craft" => { "Delivery" => 1.5, "Quality" => 1.5 } },
                   rated: { "Delivery" => true, "Quality" => false },
                   category_scores: { "cat-Craft" => { score: 1.5, scorable: true } })

      assert_in_delta 1.5, half.groups.first.score, 0.001
    end

    should "stay hidden while the chip bar would hold it back" do
      assert_nil with_category_score(rated: false).groups.first.score
    end
  end

  context "a ladder of the framework's own" do
    PM = [ { ordinal: 10, level_code: "PM1" }, { ordinal: 20, level_code: "PM2" },
           { ordinal: 40, level_code: "PM4" } ].freeze

    should "measure how far up the ladder a position sits by its steps, not its ordinals" do
      gapped = shape({ "Product" => { "Discovery" => 1.0 } }, levels: PM, person_level: 20)

      assert_equal [ 0.0, 0.5, 1.0 ], [ 0, 1, 2 ].map { |position| gapped.fraction(position) }
    end

    should "treat a one-level ladder's only level as its top" do
      one = shape({ "Product" => { "Discovery" => 1.0 } }, levels: PM.first(1), person_level: 10)

      assert_in_delta 1.0, one.fraction(0), 0.001
      assert_equal "PM1 met", point(one, "Discovery").label
    end

    should "read its codes across gaps between ordinals" do
      mid = point(shape({ "Product" => { "Discovery" => 1.5 } }, levels: PM, person_level: 20), "Discovery")

      assert_equal "PM2 + 50% to PM4", mid.label
    end

    should "hold a capability short of the first level at the centre, saying how much of it is shown" do
      short = point(shape({ "Product" => { "Discovery" => 0.6 } }, levels: PM, person_level: 10), "Discovery")

      assert_in_delta 0.0, short.reached, 0.001
      assert_equal "60% of PM1", short.label
    end
  end
end
