# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::CostCentreTest < ActiveSupport::TestCase
  Kind = TeamPlanning::RuleKinds::CostCentre

  def match(value, unit_ids: %w[squad tribe], role_id: "se", role_family_id: "eng", level_ordinal: 3, location: "Fixtureland")
    Kind.match(value, unit_ids:, role_id:, role_family_id:, level_ordinal:, location:)
  end

  def first_match(rules, unit_ids:, role_id:, role_family_id:)
    rules.index do |rule|
      (rule["unit_id"].nil? || unit_ids.include?(rule["unit_id"])) && (rule["role_id"].nil? || rule["role_id"] == role_id) &&
        (rule["role_family_id"].nil? || rule["role_family_id"] == role_family_id)
    end
  end

  should "be built in, holding no entries until a tenant or plan sets some" do
    assert_equal Kind, TeamPlanning::RuleKinds.fetch("cost_centre")
    assert_equal({ "entries" => [] }, TeamPlanning::RuleKinds.defaults["cost_centre"])
  end

  should "store each entry with its ids downcased, its level a number and its label and location squished" do
    value = TeamPlanning::RuleKinds.check("cost_centre", { entries: [ { unit_id: " TRIBE ", role_family_id: "Eng", level_ordinal: "3",
                                                                        location: " New   Zealand ", cost_centre: " Platform  Eng " } ] })

    assert_equal({ "entries" => [ { "unit_id" => "tribe", "role_family_id" => "eng", "level_ordinal" => 3, "location" => "New Zealand",
                                    "cost_centre" => "Platform Eng" } ] }, value)
  end

  should "let the last entry that matches have the last word, as in the worked example" do
    entries = { "entries" => [ { "role_family_id" => "eng", "cost_centre" => "Engineering" },
                               { "role_family_id" => "product", "cost_centre" => "Product" },
                               { "unit_id" => "venues", "cost_centre" => "Venues" } ] }

    assert_equal [ "Venues", 2 ], match(entries, unit_ids: %w[venues tribe]).then { [ it[0]["cost_centre"], it[1] ] }
    assert_equal [ "Engineering", 0 ], match(entries).then { [ it[0]["cost_centre"], it[1] ] }
    assert_nil match(entries, role_family_id: "design")
    assert_nil match({ "entries" => [] })
  end

  should "match a level number and a location, the location ignoring case and spacing" do
    entries = { "entries" => [ { "level_ordinal" => 3, "cost_centre" => "Seniors" }, { "location" => "Fixtureland", "cost_centre" => "Local" } ] }

    assert_equal "Local", match(entries, location: " FIXTURELAND ")[0]["cost_centre"]
    assert_equal "Seniors", match(entries, location: "Testonia")[0]["cost_centre"]
    assert_nil match(entries, level_ordinal: 2, location: nil)
  end

  should "read a stored first-match rules list in reverse, and convert one given to it" do
    rules = [ { "role_id" => "em", "cost_centre" => "Managers" }, { "unit_id" => "tribe", "cost_centre" => "Tribe" } ]

    assert_equal rules.reverse, Kind.entries({ "rules" => rules })
    assert_equal({ "entries" => rules.reverse }, Kind.check({ "rules" => rules }))
    assert_raises(TeamPlanning::Error) { Kind.check({ "rules" => rules, "entries" => rules }) }
  end

  should "give every stored rules list the same answer for every seat as first match did" do
    ids = { "unit_id" => %w[squad tribe venues], "role_id" => %w[se em], "role_family_id" => %w[eng design] }
    random = Random.new(387)
    seats = ids["unit_id"].flat_map { |unit| ids["role_id"].product(ids["role_family_id"]).map { |role, family| [ [ unit, "tribe" ], role, family ] } }

    50.times do
      rules = Array.new(random.rand(0..6)) do |n|
        picked = ids.keys.select { random.rand(2).zero? }.presence || [ "unit_id" ]
        picked -= [ "role_family_id" ] if picked.include?("role_id")
        picked.to_h { [ it, ids[it].sample(random:) ] }.merge("cost_centre" => "CC #{n}")
      end

      [ { "rules" => rules }, Kind.check({ "rules" => rules }) ].each do |stored|
        seats.each do |unit_ids, role_id, role_family_id|
          expected = first_match(rules, unit_ids:, role_id:, role_family_id:)
          entry, = Kind.match(stored, unit_ids:, role_id:, role_family_id:)

          assert_equal [ expected && rules[expected]["cost_centre"] ], [ entry&.dig("cost_centre") ], "#{rules.inspect} for #{[ unit_ids, role_id, role_family_id ].inspect}"
        end
      end
    end
  end

  should "refuse another key, an entry without a matcher or label, a role with a family, a bad level and a long label" do
    [ { "teams" => [] }, { "entries" => {} }, { "entries" => [ "x" ] },
      { "entries" => [ { "cost_centre" => "Ops" } ] },
      { "entries" => [ { "unit_id" => "tribe" } ] },
      { "entries" => [ { "unit_id" => "tribe", "cost_centre" => "Ops", "country" => "AU" } ] },
      { "entries" => [ { "role_id" => "se", "role_family_id" => "eng", "cost_centre" => "Ops" } ] },
      { "entries" => [ { "level_ordinal" => 0, "cost_centre" => "Ops" } ] },
      { "entries" => [ { "level_ordinal" => "two", "cost_centre" => "Ops" } ] },
      { "entries" => [ { "unit_id" => "tribe", "cost_centre" => "x" * 121 } ] },
      { "entries" => Array.new(Kind::MAX_ENTRIES + 1) { { "unit_id" => "tribe", "cost_centre" => "Ops" } } } ].each do |value|
      assert_raises(TeamPlanning::Error, value.inspect.truncate(80)) { Kind.check(value) }
    end
  end
end
