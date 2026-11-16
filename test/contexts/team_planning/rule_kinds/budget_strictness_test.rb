# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::BudgetStrictnessTest < ActiveSupport::TestCase
  def kind = TeamPlanning::RuleKinds::BudgetStrictness

  def check(value) = TeamPlanning::RuleKinds.check("budget_strictness", value)

  def refusal(value) = assert_raises(TeamPlanning::Error) { check(value) }.message

  should "default to position control: every dimension matches and each line holds money and heads" do
    default = TeamPlanning::RuleKinds.defaults.fetch("budget_strictness")
    assert_equal({ "match" => %w[role level cost_centre location], "limit" => "both", "scope" => "line" }, default)
    assert_equal "position_control", kind.preset_of(default)
    assert kind.money?(default)
    assert kind.heads?(default)
  end

  should "write a preset out as match, limit and scope" do
    assert_equal({ "match" => %w[cost_centre], "limit" => "both", "scope" => "cost_centre" }, check({ preset: "cost_centre" }))
    assert_equal({ "match" => [], "limit" => "money", "scope" => "organisation" }, check({ preset: "envelope" }))
    assert_not kind.heads?(check({ preset: "envelope" }))
  end

  should "keep a setting between the presets, its dimensions in a fixed order" do
    value = check({ match: %w[level cost_centre], limit: "heads", scope: "cost_centre" })

    assert_equal({ "match" => %w[level cost_centre], "limit" => "heads", "scope" => "cost_centre" }, value)
    assert_nil kind.preset_of(value)
    assert_not kind.money?(value)
  end

  should "refuse a cost-centre scope whose draws could cross cost centres" do
    assert_equal "A cost_centre scope needs cost_centre in match, or a draw could cross the cost centres its limit is checked in",
                 refusal({ match: %w[role], limit: "money", scope: "cost_centre" })
  end

  should "refuse an unknown preset, a preset with other keys, and bad values" do
    assert_equal "preset must be position_control, cost_centre, envelope", refusal({ preset: "loose" })
    assert_equal "A budget_strictness preset stands alone, without match, limit or scope", refusal({ preset: "envelope", scope: "line" })
    assert_equal "A budget_strictness preset stands alone, without match, limit or scope",
                 refusal({ preset: "envelope", match: [], limit: "money", scope: "organisation" })
    assert_equal "match must be a list of role, level, cost_centre, location", refusal({ match: %w[grade], limit: "money", scope: "line" })
    assert_equal "limit must be money, heads, both", refusal({ match: [], limit: "people", scope: "line" })
    assert_equal "scope must be line, cost_centre, organisation", refusal({ match: [], limit: "money", scope: "unit" })
    assert_equal "A budget_strictness rule takes a preset, or match, limit and scope, not currency",
                 refusal({ match: [], limit: "money", scope: "line", currency: "EUR" })
  end

  should "keep its presets from being changed through the default" do
    assert_raises(FrozenError) { kind.default["scope"] = "organisation" }
    assert_raises(FrozenError) { kind.default["match"] << "grade" }
  end

  should "tell a client it takes a preset alone, or match, limit and scope together" do
    assert_equal [ { required: %w[preset], not: { anyOf: [ { required: %w[match] }, { required: %w[limit] }, { required: %w[scope] } ] } },
                   { required: %w[match limit scope], not: { required: %w[preset] } } ], kind.json_schema[:oneOf],
                 "a preset takes nothing beside it, and settings written out take no preset, as check refuses both"
  end

  should "be plan-wide" do
    assert kind.plan_wide?
  end
end
