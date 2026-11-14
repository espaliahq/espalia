# frozen_string_literal: true

require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  def filtered(params) = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)

  should "keep pay band figures out of the log, from the form and from a tool call" do
    assert_equal({ "pay_band" => "[FILTERED]" }, filtered("pay_band" => { "minimum" => "100000" }))
    assert_equal({ "arguments" => { "midpoint" => "[FILTERED]" } }, filtered("arguments" => { "midpoint" => "120000" }))
  end

  should "leave a band's id and other limits readable" do
    assert_equal({ "pay_band_id" => "id", "maximum_rows" => 3 }, filtered("pay_band_id" => "id", "maximum_rows" => 3))
  end
end
