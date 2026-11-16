# frozen_string_literal: true

require "test_helper"

class PayFigureAssertionsTest < ActiveSupport::TestCase
  FIGURE = "92417"
  ID = "0198a3c2-7d10-7e55-8b1f-8592417c647a"
  DIGEST = "#{FIGURE}#{'a' * 59}"

  should "pass over a figure that only an id or a digest holds" do
    assert_no_pay_figure({ person_id: ID, upper: ID.upcase, signature: DIGEST }, FIGURE)
  end

  should "find a figure outside an id, in text or in a payload" do
    [ "pay #{FIGURE}", { pay: FIGURE, person_id: ID }, { cost: "#{FIGURE}.12" } ].each do |output|
      assert_raises(Minitest::Assertion) { assert_no_pay_figure output, FIGURE }
      assert_pay_figure output, FIGURE
    end
  end

  should "find a figure written right beside an id" do
    [ "#{FIGURE}#{ID}", "#{ID}#{FIGURE}", "#{FIGURE} #{ID}" ].each do |output|
      assert_raises(Minitest::Assertion) { assert_no_pay_figure output, FIGURE }
    end
  end

  should "never make a figure out of the digits on either side of an id" do
    assert_no_pay_figure "924#{ID}17", FIGURE
    assert_raises(Minitest::Assertion) { assert_pay_figure "924#{ID}17", FIGURE }
  end

  should "not count a figure that only an id holds as shown" do
    assert_raises(Minitest::Assertion) { assert_pay_figure({ person_id: ID }, FIGURE) }
  end

  should "refuse a figure that could never be found" do
    [ "", nil, 92_417, ID, "<id>" ].each do |figure|
      assert_raises(ArgumentError) { assert_no_pay_figure "pay", figure }
    end
  end
end
