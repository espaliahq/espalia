# frozen_string_literal: true

require "test_helper"

class LastMatchTest < ActiveSupport::TestCase
  FIELDS = %i[unit level].freeze

  should "give the last word to the last entry that matches, ignoring the fields an entry leaves unset" do
    entries = [ { level: 3 }, { unit: "sales", level: 3 }, { unit: "eng", level: 3 }, { unit: "ops", level: 4 } ]

    assert_equal [ entries[2], 2 ], LastMatch.find(entries, { unit: "eng", level: 3 }, FIELDS)
    assert_equal [ entries[0], 0 ], LastMatch.find(entries, { unit: "ops", level: 3 }, FIELDS)
    assert_nil LastMatch.find(entries, { unit: "ops", level: 5 }, FIELDS)
  end

  should "read each entry's matcher through the block" do
    rule = Struct.new(:matcher, :name)
    entries = [ rule.new({}, "fallback"), rule.new({ unit: "eng" }, "eng") ]

    assert_equal "eng", LastMatch.find(entries, { unit: "eng" }, FIELDS, &:matcher).first.name
  end

  should "find the entries a later entry matches every subject of" do
    matchers = [ { unit: "eng", level: 3 }, { level: 3 }, { unit: "eng" } ]

    assert_equal [ 0 ], LastMatch.shadowed(matchers, FIELDS)
    assert_equal [], LastMatch.shadowed(matchers.reverse, FIELDS)
  end

  should "match a subject that sits in a set of values, as a seat sits in its unit and every unit above" do
    entries = [ { unit: "company" }, { unit: "eng", level: 3 }, { unit: "payments" } ]
    seat = { unit: Set["platform", "eng", "company"], level: 3 }

    assert_equal 1, LastMatch.find(entries, seat, FIELDS).last
    assert_equal 0, LastMatch.find(entries, seat.merge(level: 4), FIELDS).last
    assert_equal [ 0 ], LastMatch.shadowed([ { unit: "eng", level: 3 }, { unit: "company" } ], FIELDS,
                                           reaches: [ { unit: Set["eng", "company"], level: 3 }, { unit: Set["company"] } ])
  end
end
