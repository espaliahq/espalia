# frozen_string_literal: true

require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  def filtered(params) = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)

  should "keep pay band figures out of the log, from the form and from a tool call" do
    assert_equal({ "pay_band" => "[FILTERED]" }, filtered("pay_band" => { "minimum" => "100000" }))
    assert_equal({ "arguments" => { "midpoint" => "[FILTERED]" } }, filtered("arguments" => { "midpoint" => "120000" }))
  end

  should "keep exchange rates out of the log, from the form and from a tool call" do
    assert_equal({ "exchange_rate" => "[FILTERED]" }, filtered("exchange_rate" => { "rate" => "0.5" }))
    assert_equal({ "arguments" => { "rate" => "[FILTERED]" } }, filtered("arguments" => { "rate" => "0.5" }))
    assert_equal({ "exchange_rate_id" => "id", "frequency" => "often" }, filtered("exchange_rate_id" => "id", "frequency" => "often"))
  end

  should "keep budget line amounts and head counts out of the log, from the form and from a tool call" do
    assert_equal({ "budget_line" => "[FILTERED]" }, filtered("budget_line" => { "amount" => "120000" }))
    assert_equal({ "arguments" => { "amount" => "[FILTERED]", "head_count" => "[FILTERED]" } },
                 filtered("arguments" => { "amount" => "120000", "head_count" => "2" }))
    assert_equal({ "budget_line_id" => "id" }, filtered("budget_line_id" => "id"))
  end

  should "keep actual pay out of the log, from a form and from a tool call" do
    assert_equal({ "pay" => "[FILTERED]" }, filtered("pay" => { "amount" => "92000", "basis" => "actual" }))
    assert_equal({ "arguments" => { "amount" => "[FILTERED]", "currency" => "AUD" } }, filtered("arguments" => { "amount" => "92000", "currency" => "AUD" }))
  end

  should "leave a band's id and other limits readable" do
    assert_equal({ "pay_band_id" => "id", "maximum_rows" => 3 }, filtered("pay_band_id" => "id", "maximum_rows" => 3))
  end
end
