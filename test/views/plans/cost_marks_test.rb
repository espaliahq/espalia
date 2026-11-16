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
    marks = Struct.new(:total, :reference, :cost, :outside_units, :unpriced) { def run_rate? = false }.new(
      { scenario: sum({ "EUR" => "100" }, "100"), baseline: sum({ "GBP" => "80" }, nil, [ "No GBP rate." ]),
        difference: sum({ "EUR" => "100", "GBP" => "-80" }),
        parts: { actual: sum({ "GBP" => "80" }, nil, [ "No GBP rate." ]), planned: sum({ "EUR" => "100", "GBP" => "-80" }), forecast: sum({}) } },
      "EUR", { period: { starts_on: "2026-01-01", ends_on: "2026-12-31" } }, nil, []
    )
    strip = Nokogiri::HTML5.fragment(Views::Plans::CostStrip.new(marks:).call)

    assert_equal "Not totalled in one currency: no GBP rate.", strip.at_css("[data-cost-missing]").text
  end

  should "name actual pay in the basis for a holder whose plan holds some, and midpoints otherwise" do
    basis = lambda do |cost|
      marks = Struct.new(:total, :reference, :cost, :outside_units, :unpriced) { def run_rate? = false }.new(
        { scenario: sum({ "EUR" => "100" }, "100"), baseline: sum({ "EUR" => "100" }, "100"), difference: sum({}, "0"),
          parts: { actual: sum({ "EUR" => "100" }, "100"), planned: sum({}, "0"), forecast: sum({}, "0") } },
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

  should "give Today in the table as a run rate set against nothing, and say a scenario can't be priced" do
    row = { scenario_id: "p", basis: "run_rate", total: { scenario: sum({ "EUR" => "1200000" }, "1200000") }, unpriced: 0 }
    today = Nokogiri::HTML5.fragment(Views::Plans::CostCell.new(row:, reference: "EUR").call)
    broken = Nokogiri::HTML5.fragment(Views::Plans::CostCell.new(row: { scenario_id: "s", error: "No period" }, reference: "EUR").call)

    assert_equal "EUR 1.2m a year(run rate)", today.text
    assert_equal [ "Can't be priced", "No period" ], [ broken.text, broken.at_css("span")["title"] ]
  end

  context "the actual, planned and forecast split" do
    should "give each part, signing planned and forecast, and leave forecast out until it adds something" do
      parts = { actual: sum({ "EUR" => "1200000" }, "1200000"), planned: sum({ "EUR" => "-40000" }, "-40000"), forecast: sum({ "EUR" => "0" }, "0") }

      assert_equal [ [ "Actual", "EUR 1.2m" ], [ "Planned", "-EUR 40k" ] ], Format.parts(parts, "EUR")
      assert_equal [ [ "Actual", "EUR 1.2m" ], [ "Planned", "-EUR 40k" ], [ "Forecast", "+EUR 15k" ] ],
                   Format.parts(parts.merge(forecast: sum({ "EUR" => "15000" }, "15000")), "EUR")
      assert_equal [ [ "Actual", "EUR 1.2m" ], [ "Planned", "EUR 0" ] ], Format.parts(parts.merge(planned: sum({}, "0")), "EUR")
    end

    should "name no currency for a planned part of nothing it cannot tell the currency of" do
      none = { native: {}, converted: nil, missing: [] }
      native = ->(figures) { { native: figures, converted: nil, missing: [] } }

      assert_equal [ [ "Actual", "nothing" ], [ "Planned", "nothing" ] ], Format.parts({ actual: none, planned: none, forecast: none }, nil)
      assert_equal [ "Planned", "GBP 0" ], Format.parts({ actual: native.({ "GBP" => "10" }), planned: none, forecast: none }, nil)[1]
      assert_equal [ "Planned", "nothing" ],
                   Format.parts({ actual: native.({ "EUR" => "10", "GBP" => "10" }), planned: none, forecast: none }, nil)[1]
    end

    should "draw the split under a unit's figure and a table cell, and nothing under a run rate" do
      parts = { actual: sum({ "EUR" => "100000" }, "100000"), planned: sum({ "EUR" => "-20000" }, "-20000"), forecast: sum({ "EUR" => "5000" }, "5000") }
      figures = { scenario: sum({ "EUR" => "85000" }, "85000"), baseline: parts[:actual], difference: sum({ "EUR" => "-15000" }, "-15000"), parts: }
      unit = Nokogiri::HTML5.fragment(Views::Plans::CostUnitTotal.new(row: { unit_id: "u", **figures }, reference: "EUR").call)
      cell = Nokogiri::HTML5.fragment(Views::Plans::CostCell.new(row: { scenario_id: "s", total: figures, unpriced: 0 }, reference: "EUR").call)
      today = Nokogiri::HTML5.fragment(
        Views::Plans::CostUnitTotal.new(row: { unit_id: "u", scenario: parts[:actual], parts: { **parts, planned: sum({}, "0"), forecast: sum({}, "0") } },
                                        reference: "EUR", run_rate: true).call
      )

      [ unit, cell ].each do |html|
        assert_equal [ "Actual EUR 100k", "Planned -EUR 20k", "Forecast +EUR 5k" ], html.css("[data-figure-parts] [data-part]").map(&:text)
      end
      assert_nil today.at_css("[data-figure-parts]")
    end
  end
end
