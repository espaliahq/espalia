# frozen_string_literal: true

require "test_helper"

class Hris::FieldTest < ActiveSupport::TestCase
  should "refuse a kind other than list or text" do
    assert_raises(ArgumentError) { Hris::Field.new(id: "work.site", name: "Site", kind: :date) }
  end

  should "default to no values and freeze the ones it is given" do
    assert_empty Hris::Field.new(id: "root.id", name: "Employee ID", kind: :text).values
    assert_predicate Hris::Field.new(id: "work.site", name: "Site", kind: :list, values: []).values, :frozen?
  end
end
