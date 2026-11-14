# frozen_string_literal: true

require "test_helper"

class Views::Plans::CostMarksTest < ActiveSupport::TestCase
  Format = Views::Plans::CostMarks::Format

  def sum(native, converted = nil, missing = []) = { native:, converted:, missing: }

  should "round a figure to three significant figures, dropping zeros that carry nothing" do
    expected = { "950" => "EUR 950", "999.4" => "EUR 999", "999.5" => "EUR 1k", "1049.9" => "EUR 1.05k", "5000" => "EUR 5k",
                 "9994" => "EUR 9.99k", "9995" => "EUR 10k", "148300" => "EUR 148k", "999499" => "EUR 999k",
                 "999500" => "EUR 1m", "3214000" => "EUR 3.21m", "-4200" => "-EUR 4.2k" }
    assert_equal expected, expected.keys.index_with { Format.amount(it, "EUR") }
  end

  should "sign a change, and give nothing when there is none" do
    assert_equal "+EUR 148k", Format.change("148000", "EUR")
    assert_equal "-EUR 2.5k", Format.change("-2500", "EUR")
    assert_nil Format.change("0", "EUR")
  end

  should "give the converted total when there is one, and each currency's otherwise" do
    assert_equal "EUR 250k", Format.sum(sum({ "EUR" => "150000", "GBP" => "80000" }, "250000"), "EUR")
    assert_equal "EUR 150k + GBP 80k", Format.sum(sum({ "EUR" => "150000", "GBP" => "80000" }), "EUR")
    assert_equal "nothing", Format.sum(sum({}), "EUR")
    assert_equal "+EUR 5k, -GBP 1k", Format.sum_change(sum({ "EUR" => "5000", "GBP" => "-1000", "AUD" => "0" }), nil)
    assert_nil Format.sum_change(sum({ "EUR" => "0" }, "0"), "EUR")
  end

  should "say in the table that Today has no period, and that a scenario can't be priced" do
    today = Views::Plans::CostCell.new(row: nil, reference: "EUR").call
    broken = Nokogiri::HTML5.fragment(Views::Plans::CostCell.new(row: { scenario_id: "s", error: "No period" }, reference: "EUR").call)

    assert_includes today, "No period of its own"
    assert_equal [ "Can't be priced", "No period" ], [ broken.text, broken.at_css("span")["title"] ]
  end
end
