# frozen_string_literal: true

require "test_helper"

class Views::Plans::CostMarksTest < ActiveSupport::TestCase
  Format = Views::Plans::CostMarks::Format

  def sum(native, converted = nil, missing = []) = { native:, converted:, missing: }

  should "round a figure to three significant figures, dropping zeros that carry nothing" do
    expected = { "950" => "EUR 950", "999.4" => "EUR 999", "999.5" => "EUR 1k", "1049.9" => "EUR 1.05k", "5000" => "EUR 5k",
                 "9994" => "EUR 9.99k", "9995" => "EUR 10k", "12345" => "EUR 12.3k", "148300" => "EUR 148k", "999499" => "EUR 999k",
                 "999500" => "EUR 1m", "3214000" => "EUR 3.21m", "-4200" => "-EUR 4.2k", "-0.37" => "EUR 0" }
    assert_equal expected, expected.keys.index_with { Format.amount(it, "EUR") }
  end

  should "sign a change, and give nothing when there is none" do
    assert_equal "+EUR 148k", Format.change("148000", "EUR")
    assert_equal "-EUR 2.5k", Format.change("-2500", "EUR")
    assert_nil Format.change("0", "EUR")
    assert_nil Format.change("-0.37", "EUR")
  end

  should "give the converted total when there is one, and each currency's otherwise" do
    assert_equal "EUR 250k", Format.sum(sum({ "EUR" => "150000", "GBP" => "80000" }, "250000"), "EUR")
    assert_equal "EUR 150k + GBP 80k", Format.sum(sum({ "EUR" => "150000", "GBP" => "80000" }), "EUR")
    assert_equal "nothing", Format.sum(sum({}), "EUR")
    assert_equal "+EUR 5k, -GBP 1k", Format.sum_change(sum({ "EUR" => "5000", "GBP" => "-1000", "AUD" => "0" }), nil)
    assert_nil Format.sum_change(sum({ "EUR" => "0" }, "0"), "EUR")
  end

  should "say why a total isn't in one currency when only Today's fails to convert" do
    marks = Struct.new(:total, :reference, :cost, :outside_units, :unpriced).new(
      { scenario: sum({ "EUR" => "100" }, "100"), baseline: sum({ "GBP" => "80" }, nil, [ "No GBP rate." ]),
        difference: sum({ "EUR" => "100", "GBP" => "-80" }) },
      "EUR", { period: { starts_on: "2026-01-01", ends_on: "2026-12-31" } }, nil, []
    )
    strip = Nokogiri::HTML5.fragment(Views::Plans::CostStrip.new(marks:).call)

    assert_equal "Not totalled in one currency: no GBP rate.", strip.at_css("[data-cost-missing]").text
  end

  should "name actual pay in the basis for a holder whose plan holds some, and midpoints otherwise" do
    basis = lambda do |cost|
      marks = Struct.new(:total, :reference, :cost, :outside_units, :unpriced).new(
        { scenario: sum({ "EUR" => "100" }, "100"), baseline: sum({ "EUR" => "100" }, "100"), difference: sum({}, "0") },
        "EUR", { period: { starts_on: "2026-01-01", ends_on: "2026-12-31" }, **cost }, nil, []
      )
      Nokogiri::HTML5.fragment(Views::Plans::CostStrip.new(marks:).call).at_css("p.text-muted").text
    end

    assert_includes basis.({ actual_pay_seats: { scenario: 1, baseline: 2 } }),
                    "Priced from the actual pay the plan holds for 1 seat here and 2 seats in Today, and at pay band midpoints for the rest, plus"
    assert_includes basis.({ actual_pay_seats: { scenario: 0, baseline: 3 } }),
                    "Priced from the actual pay the plan holds for 3 seats in Today, and at pay band midpoints for the rest"
    [ {}, { actual_pay_seats: { scenario: 0, baseline: 0 } }, { actual_pay_seats: { scenario: nil, baseline: nil } } ].each do |cost|
      assert_includes basis.(cost), "the scenario this one follows. Priced at pay band midpoints, plus", cost.inspect
    end
  end

  should "say in the table that Today has no period, and that a scenario can't be priced" do
    today = Views::Plans::CostCell.new(row: nil, reference: "EUR").call
    broken = Nokogiri::HTML5.fragment(Views::Plans::CostCell.new(row: { scenario_id: "s", error: "No period" }, reference: "EUR").call)

    assert_includes today, "No period of its own"
    assert_equal [ "Can't be priced", "No period" ], [ broken.text, broken.at_css("span")["title"] ]
  end
end
