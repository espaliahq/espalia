# frozen_string_literal: true

require "test_helper"

# The capability map: the radar beside one lane per capability, grouped by
# category, each saying in words how far along the ladder it is.
class Views::Assessments::CapabilityMapModalTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)
  E1_TO_E5 = (1..5).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze

  def render_map(rated: { "Delivery" => true, "Quality" => true, "Mentoring" => false }, statuses: {})
    scores = { "Delivery" => 1.5, "Quality" => 1.25, "Mentoring" => 1.0 }
    groups = { "Craft" => %w[Delivery Quality], "People" => %w[Mentoring] }
    categories = groups.map do |category, names|
      { category: CATEGORY.new(category_id: "cat-#{category}", name: category), person_level: 3,
        capabilities: names.map do |name|
          { capability: CAP.new(stable_id: "cap-#{name}", name: name),
            cells: { 3 => { current_frequency: rated.fetch(name) ? "consistent" : nil } } }
        end }
    end
    shape = Assessments::CapabilityShape.new(
      categories: categories, merged_levels: E1_TO_E5, person_level: 3, context: :self,
      scoring: {
        capability_scores: scores.to_h { |n, s| [ "cap-#{n}", { score: s, scorable: true, required: false } ] },
        capability_statuses: statuses,
        category_scores: { "cat-Craft" => { score: 1.38, scorable: true, state: :performing },
                           "cat-People" => { score: 1.0, scorable: true } }
      }
    )
    Nokogiri::HTML5.fragment(Views::Assessments::CapabilityMapModal.new(shape: shape, subject: "Alex at E3").call)
  end

  def words(node) = node.xpath(".//text()").map { |t| t.text.strip }.reject(&:empty?)

  should "show the radar beside a lane per capability, grouped under each category with its score" do
    map = render_map

    assert map.at_css("##{Views::Assessments::CapabilityMapModal::ID} svg[role='group']"), "expected the radar"
    lanes = map.css("[data-capability-lane]")
    assert_equal [ [ "1", "Delivery", "E3 + 50% to E4" ], [ "2", "Quality", "E3 + 25% to E4" ],
                   [ "3", "Mentoring", "Not rated" ] ],
                 lanes.map { |l| words(l) }
    assert_equal [ %w[Craft 138%], %w[People] ], map.css("[data-capability-lane-group]").map { |g| words(g) }
  end

  should "link each lane to its capability's card at the assessed level" do
    lane = render_map.at_css("[data-capability-lane='1']")

    assert_equal "a", lane.name
    assert_equal "#cell-cap-Delivery-3", lane["href"]
  end

  should "mark a lane whose capability blocks the score, in words" do
    map = render_map(statuses: { "cap-Quality" => :blocked })

    assert_includes words(map.at_css("[data-capability-lane='2']")), "! Blocked"
    assert_not_includes words(map.at_css("[data-capability-lane='1']")), "! Blocked"
  end

  should "colour a category's score by its state, as the section header does" do
    craft = render_map.at_css("[data-capability-lane-group='Craft']")

    assert craft.at_css(".text-score-performing", text: "138%"), "expected Craft's 138% in the performing tone"
  end
end
