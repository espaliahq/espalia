# frozen_string_literal: true

require "test_helper"

# The comparison tab's blades: the person's, with a line across each blade at
# the group's median on the same scale as the blade.
class Views::Assessments::ComparisonBladesTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)
  LEVELS = (1..5).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze

  def shape(scores)
    categories = [ { category: CATEGORY.new(category_id: "cat", name: "Craft"), person_level: 3,
                     capabilities: scores.keys.map do |name|
                       { capability: CAP.new(stable_id: "cap-#{name}", name: name),
                         cells: { 3 => { current_frequency: "consistent" } } }
                     end } ]
    Assessments::CapabilityShape.new(
      categories: categories, merged_levels: LEVELS, person_level: 3, context: :self,
      scoring: { capability_scores: scores.to_h { |name, score| [ "cap-#{name}", { score: score, scorable: true } ] },
                 capability_statuses: {} }
    )
  end

  def render_blades(medians)
    picture = Views::Assessments::ComparisonBlades.new(shape: shape({ "Delivery" => 1.0, "Quality" => 0.5, "Testing" => 1.0 }),
                                                       medians: medians, label: "2 of 3 at or above").call
    Nokogiri::HTML5.fragment(picture)
  end

  def line_radius(picture, number) = picture.at_css("[data-blade-median='#{number}']")["d"].scan(/A(\d+(?:\.\d+)?)/).first.first.to_f

  should "draw the group's line at its median: the dashed edge when met, past it when ahead, inside when short" do
    picture = render_blades({ "cap-Delivery" => 1.0, "cap-Quality" => 1.5, "cap-Testing" => 0.5 })

    assert_equal [ 22.0, 26.0, 11.0 ], (1..3).map { |n| line_radius(picture, n) }
  end

  should "draw the line all the way round when there is only one capability" do
    picture = Views::Assessments::ComparisonBlades.new(shape: shape({ "Delivery" => 1.0 }), medians: { "cap-Delivery" => 1.0 },
                                                       label: "1 of 1 at or above").call
    ends = Nokogiri::HTML5.fragment(picture).at_css("[data-blade-median='1']")["d"].scan(/(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)(?= A| *\z)/)

    assert_operator ends.uniq.size, :>, 1, "an arc that ends where it starts draws nothing"
  end

  should "draw no line where the group has no median" do
    picture = render_blades({ "cap-Delivery" => 1.0 })

    assert_equal %w[1], picture.css("[data-blade-median]").map { |line| line["data-blade-median"] }
  end

  should "name what it shows, once" do
    picture = render_blades({}).at_css("svg")

    assert_equal [ "img", "2 of 3 at or above" ], [ picture["role"], picture["aria-label"] ]
  end
end
