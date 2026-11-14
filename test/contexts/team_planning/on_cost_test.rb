# frozen_string_literal: true

require "test_helper"

class TeamPlanning::OnCostTest < ActiveSupport::TestCase
  RULE = TeamPlanning::RuleKinds::OnCost

  def on_cost(value, base: 100_000, currency: "EUR", country: nil, share: 1)
    RULE.on_cost_of(TeamPlanning::RuleKinds.check("on_cost", value), base:, currency:, country:, share:)
  end

  def refusal(value) = assert_raises(TeamPlanning::Error) { TeamPlanning::RuleKinds.check("on_cost", value) }.message

  should "add nothing until a tenant or plan chooses a model" do
    assert_equal 0, RULE.on_cost_of(RULE.default, base: 100_000, currency: "EUR", country: nil).amount
  end

  should "add one percentage of base pay, exactly" do
    figure = on_cost({ model: "flat", params: { percent: "12.5" } }, base: 100_001)

    assert_equal Rational(100_001, 8), figure.amount
    assert_equal [ "12.5% of base pay" ], figure.working.map(&:label)
  end

  should "take a country's own percentage, ignoring case and spacing, and the fallback for any other" do
    value = { model: "by_country", params: { percents: { " Atlantis " => "14", "Lemuria" => 9 }, otherwise: "10" } }

    assert_equal [ 14_000, 9_000, 10_000, 10_000 ], [ "atlantis", "LEMURIA", "Mu", nil ].map { on_cost(value, country: it).amount }
    assert_equal [ "14% of base pay, in Atlantis", "10% of base pay, in a country not listed", "10% of base pay, with no country recorded" ],
                 [ "atlantis", "Mu", nil ].map { on_cost(value, country: it).working.sole.label }
  end

  should "sum named parts, scaling a fixed amount by the share of a full-time year" do
    value = { model: "itemised", params: { items: [ { name: "Pension", percent: "9" }, { name: "Equipment", amount: "1200", currency: "eur" } ] } }
    figure = on_cost(value, base: 50_000, share: Rational(1, 2))

    assert_equal 4_500 + 600, figure.amount
    assert_equal [ 4_500, 600 ], figure.working.map(&:amount)
    assert_equal [ "Equipment: a fixed amount, for 50% of a full-time year", "Equipment: a fixed amount, for 33.33% of a full-time year",
                   "Equipment: a fixed amount, for a full-time year" ],
                 [ Rational(1, 2), Rational(1, 3), 1 ].map { on_cost(value, share: it).working.last.label }
  end

  should "refuse to price a fixed amount in another currency than the seat's" do
    value = { model: "itemised", params: { items: [ { name: "Equipment", amount: "1200", currency: "EUR" } ] } }

    refused = assert_raises(TeamPlanning::Error) { on_cost(value, currency: "NZD") }
    assert_equal "Equipment is a fixed amount in EUR, and this seat is priced in NZD", refused.message
  end

  should "take an exact Rational, and refuse one no short decimal holds" do
    assert_equal "12.5", TeamPlanning::RuleKinds.check("on_cost", { model: "flat", params: { percent: Rational(25, 2) } })["params"]["percent"]
    assert_equal "1200.5",
                 TeamPlanning::RuleKinds.check("on_cost", { model: "itemised", params: { items: [ { name: "Kit", amount: Rational(2401, 2), currency: "EUR" } ] } })
                   .dig("params", "items", 0, "amount")
    assert_equal "A flat on-cost's percent must be a percentage, such as 12.5", refusal({ model: "flat", params: { percent: Rational(1, 3) } })
  end

  should "refuse a malformed model without repeating a figure" do
    assert_equal "No such on-cost model", refusal({ model: "guess", params: {} })
    assert_equal "An on_cost rule must give its model's params", refusal({ model: "flat" })
    assert_equal "Pension is a percentage, so it takes no currency",
                 refusal({ model: "itemised", params: { items: [ { name: "Pension", percent: "9", currency: "EUR" } ] } })
    assert_equal "A flat on-cost's percent must be a percentage, such as 12.5", refusal({ model: "flat", params: { percent: "-31.7" } })
    assert_equal "A flat on-cost takes only percent, not cap", refusal({ model: "flat", params: { percent: "1", cap: "77" } })
    assert_equal "An on-cost by country names one country twice",
                 refusal({ model: "by_country", params: { percents: { "Mu" => "1", "mu " => "2" }, otherwise: "3" } })
    assert_equal "Pension must have a percent or an amount and currency, not both",
                 refusal({ model: "itemised", params: { items: [ { name: "Pension", percent: "9", amount: "41", currency: "EUR" } ] } })
    assert_equal "Equipment's currency must be an ISO 4217 currency code, such as AUD",
                 refusal({ model: "itemised", params: { items: [ { name: "Equipment", amount: "41", currency: "QQQ" } ] } })
    assert_equal "Equipment's amount must be a number, such as 1200 or 1200.50",
                 refusal({ model: "itemised", params: { items: [ { name: "Equipment", amount: "4.1.7", currency: "EUR" } ] } })
  end

  should "describe each model's params, so a client can see their keys" do
    schema = RULE.json_schema
    assert_equal %w[flat by_country itemised], schema[:oneOf].map { it.dig(:properties, :model, :const) }
    assert_equal [ %w[model params], %w[flat by_country itemised] ], [ schema[:properties].keys.map(&:to_s), schema.dig(:properties, :model, :enum) ]

    item = TeamPlanning::OnCostModels::Itemised.params_schema.dig(:properties, :items, :items)
    assert_equal [ [ "percent" ], %w[amount currency] ], item[:oneOf].map { it[:required] }
  end
end
