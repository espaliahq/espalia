# frozen_string_literal: true

require "test_helper"

class Hris::FieldValueTest < ActiveSupport::TestCase
  should "refuse a state it does not know" do
    assert_raises(ArgumentError) { Hris::FieldValue.new(state: :missing) }
  end

  should "tell list values apart by id, so two items sharing a label stay two" do
    a = Hris::FieldValue.new(state: :value, id: "1", label: "Sales")
    b = Hris::FieldValue.new(state: :value, id: "2", label: "Sales")

    assert_not_equal a.key, b.key
  end

  should "tell text values apart by their text" do
    assert_equal "Growth", Hris::FieldValue.new(state: :value, label: "Growth").key
  end
end
