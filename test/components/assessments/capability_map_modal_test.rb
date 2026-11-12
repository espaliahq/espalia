# frozen_string_literal: true

require "test_helper"

# The capability map: the radar beside one lane per capability, grouped by
# category, each saying in words how far along the ladder it is.
class Views::Assessments::CapabilityMapModalTest < ActiveSupport::TestCase
  CAP = Struct.new(:stable_id, :name, keyword_init: true)
  CATEGORY = Struct.new(:category_id, :name, keyword_init: true)
  E1_TO_E5 = (1..5).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze
  E1_TO_E8 = (1..8).map { |n| { ordinal: n, level_code: "E#{n}" } }.freeze

  def render_map(rated: { "Delivery" => true, "Quality" => true, "Mentoring" => false }, statuses: {},
                 levels: E1_TO_E5, src: nil, zoom: :all)
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
      categories: categories, merged_levels: levels, person_level: 3, context: :self, zoom: zoom,
      scoring: {
        capability_scores: scores.to_h { |n, s| [ "cap-#{n}", { score: s, scorable: true, required: false } ] },
        capability_statuses: statuses,
        category_scores: { "cat-Craft" => { score: 1.38, scorable: true, state: :performing },
                           "cat-People" => { score: 1.0, scorable: true } }
      }
    )
    Nokogiri::HTML5.fragment(Views::Assessments::CapabilityMapModal.new(shape: shape, subject: "Alex at E3", src: src).call)
  end

  def words(node) = node.xpath(".//text()").map { |t| t.text.strip }.reject(&:empty?)

  # Each zoom toggle as [label, pressed, the zoom pressing it asks for].
  def toggles(map)
    map.css("[data-action~='capability-map#zoom']").map do |t|
      [ t.text.strip, t["aria-pressed"], t["data-capability-map-zoom-param"] ]
    end
  end

  def bar_width(map, number) = map.at_css("[data-capability-lane='#{number}'] span[style^='width']")["style"]

  context "zoomed to the assessed level on a long ladder" do
    setup { @map = render_map(levels: E1_TO_E8, zoom: nil) }

    should "head the bars with a toggle per level in view, the assessed one pressed, and an All levels toggle" do
      assert_equal [ [ "All levels", "false", "all" ], [ "E2", "false", "E2" ], [ "E3", "true", "all" ],
                     [ "E4", "false", "E4" ] ], toggles(@map)
      assert @map.at_css("[role='group'][aria-label='Zoom the map to a level']"), "expected the level toggles grouped"
    end

    should "draw each bar from the level below met to the level above" do
      assert_equal "width: 75.0%", bar_width(@map, 1), "expected E3 + 50% three quarters along"
      assert_equal 3, @map.css("[data-capability-lane='1'] span.w-px").size, "expected a tick per level in view"
    end

    should "say where the radar's centre and rim are" do
      assert_includes @map.text, "At the radar's centre is E2 met, and each ring is the next level, up to E4 at the rim."
    end
  end

  context "zoomed out on a long ladder" do
    setup { @map = render_map(levels: E1_TO_E8, zoom: :all) }

    should "press All levels, whose toggle returns to the assessed level, and head the bars with every level" do
      assert_equal [ "All levels", "true", "E3" ], toggles(@map).first
      assert_equal %w[E1 E2 E3 E4 E5 E6 E7 E8], toggles(@map).drop(1).map(&:first)
      assert toggles(@map).drop(1).all? { |_, pressed| pressed == "false" }
    end

    should "draw each bar against the whole ladder" do
      assert_equal "width: 35.71%", bar_width(@map, 1), "expected E3 + 50% two and a half steps of seven along"
    end
  end

  should "offer no zoom on a ladder of three levels, which shows whole" do
    map = render_map(levels: E1_TO_E5.first(3), zoom: nil)

    assert_empty toggles(map)
    assert_equal %w[E2 E3], map.css("[data-radar-ring]").map { |r| r["data-radar-ring"] }
  end

  should "offer no zoom when the assessed level isn't on the role's ladder" do
    map = render_map(levels: E1_TO_E8.reject { |l| l[:ordinal] == 3 }, zoom: nil)

    assert_empty toggles(map)
  end

  should "still say where a capability past the rim stands" do
    map = render_map(levels: E1_TO_E8, zoom: "E2")

    assert_equal "width: 100.0%", bar_width(map, 1)
    assert_includes words(map.at_css("[data-capability-lane='1']")), "E3 + 50% to E4"
  end

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
    assert_equal "_top", lane["data-turbo-frame"], "the map's content frame must not capture the jump"
  end

  should "mark a lane whose capability blocks the score, in words" do
    map = render_map(statuses: { "cap-Quality" => :blocked })

    assert_includes words(map.at_css("[data-capability-lane='2']")), "! Blocked"
    assert_not_includes words(map.at_css("[data-capability-lane='1']")), "! Blocked"
  end

  should "say how to read the radar from its centre on a ladder with levels to climb" do
    assert_includes render_map.text, "At the radar's centre is E1 met, and each ring is the next level. Open"
  end

  should "say a one-level ladder's rim is its level met" do
    map = render_map(levels: [ { ordinal: 3, level_code: "E3" } ])

    assert_includes map.text, "The radar's rim is E3 met."
    assert_not_includes map.text, "centre is"
  end

  should "label the assessed ring for whoever's map it is" do
    matrix_data = { person_level: 3, merged_levels: E1_TO_E5,
                    categories: [ { category: CATEGORY.new(category_id: "cat-Craft", name: "Craft"), person_level: 3,
                                    capabilities: [ { capability: CAP.new(stable_id: "cap-Delivery", name: "Delivery"),
                                                      cells: { 3 => { current_frequency: "consistent" } } } ] } ] }
    scoring = { capability_scores: { "cap-Delivery" => { score: 1.0, scorable: true, required: false } } }
    label = ->(whose) {
      map = Views::Assessments::CapabilityMapModal.for(matrix_data: matrix_data, scoring: scoring, context: :self,
                                                       whose: whose)
      Nokogiri::HTML5.fragment(map.call).at_css("[data-radar-ring-label='E3']").text
    }

    assert_equal "E3 · you", label.call(nil)
    assert_equal "E3 · assessed", label.call("Alex")
  end

  should "hold its contents in a frame that reloads only when asked, so the overlay around it stays mounted" do
    frame = render_map(src: "/assessments/1/capability_map").at_css("##{Views::Assessments::CapabilityMapModal::ID} turbo-frame")

    assert_equal Views::Assessments::CapabilityMapModal::CONTENT_ID, frame["id"]
    assert_equal "/assessments/1/capability_map", frame["data-reload-src"]
    assert_nil frame["src"], "a src would load the map on every page view"
    assert frame.at_css("[data-capability-lane='1']"), "expected the lanes inside the frame"
  end

  should "colour a category's score by its state, as the section header does" do
    craft = render_map.at_css("[data-capability-lane-group='Craft']")

    assert craft.at_css(".text-score-performing", text: "138%"), "expected Craft's 138% in the performing tone"
  end
end
