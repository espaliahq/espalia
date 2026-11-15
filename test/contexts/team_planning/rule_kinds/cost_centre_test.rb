# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::CostCentreTest < ActiveSupport::TestCase
  Kind = TeamPlanning::RuleKinds::CostCentre

  def match(value, unit_ids: %w[squad tribe], role_id: "se", family_id: "eng")
    Kind.match(Kind.check(value), unit_ids:, role_id:, family_id:)
  end

  should "be built in, holding no rules until a tenant or plan sets some" do
    assert_equal Kind, TeamPlanning::RuleKinds.fetch("cost_centre")
    assert_equal({ "rules" => [] }, TeamPlanning::RuleKinds.defaults["cost_centre"])
  end

  should "store each rule with its ids downcased and its label squished" do
    value = TeamPlanning::RuleKinds.check("cost_centre", { rules: [ { unit_id: " TRIBE ", role_family_id: "Eng", cost_centre: " Platform  Eng " } ] })

    assert_equal({ "rules" => [ { "unit_id" => "tribe", "role_family_id" => "eng", "cost_centre" => "Platform Eng" } ] }, value)
  end

  should "take the first rule that matches, a unit matching every unit below it" do
    rules = { "rules" => [ { "role_id" => "em", "cost_centre" => "Managers" },
                           { "unit_id" => "tribe", "role_family_id" => "eng", "cost_centre" => "Tribe Eng" },
                           { "unit_id" => "tribe", "cost_centre" => "Tribe" } ] }

    assert_equal [ 1, "Tribe Eng" ], match(rules).then { [ it[0], it[1]["cost_centre"] ] }
    assert_equal 0, match(rules, role_id: "em")[0]
    assert_equal 2, match(rules, family_id: "design")[0]
    assert_nil match(rules, unit_ids: %w[other], family_id: "design")
    assert_nil match({ "rules" => [] })
  end

  should "refuse another key, a rule without a matcher or label, a role with a family, and a long label" do
    [ { "teams" => [] }, { "rules" => {} }, { "rules" => [ "x" ] },
      { "rules" => [ { "cost_centre" => "Ops" } ] },
      { "rules" => [ { "unit_id" => "tribe" } ] },
      { "rules" => [ { "unit_id" => "tribe", "cost_centre" => "Ops", "location" => "AU" } ] },
      { "rules" => [ { "role_id" => "se", "role_family_id" => "eng", "cost_centre" => "Ops" } ] },
      { "rules" => [ { "unit_id" => "tribe", "cost_centre" => "x" * 121 } ] },
      { "rules" => Array.new(Kind::MAX_RULES + 1) { { "unit_id" => "tribe", "cost_centre" => "Ops" } } } ].each do |value|
      assert_raises(TeamPlanning::Error, value.inspect.truncate(80)) { Kind.check(value) }
    end
  end
end
