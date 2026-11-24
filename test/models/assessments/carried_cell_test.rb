# frozen_string_literal: true

require "test_helper"

class Assessments::CarriedCellTest < ActiveSupport::TestCase
  context ".unconfirmed?" do
    should "be true only for a seeded value on a cell nobody has agreed" do
      assert Assessments::CarriedCell.unconfirmed?("seeded", nil)
      assert_not Assessments::CarriedCell.unconfirmed?("seeded", "some")
      assert_not Assessments::CarriedCell.unconfirmed?("human", nil)
      assert_not Assessments::CarriedCell.unconfirmed?(nil, nil)
    end
  end

  context ".vetted?" do
    should "need a value, and one that no longer waits" do
      assert Assessments::CarriedCell.vetted?("some", "human", nil)
      assert Assessments::CarriedCell.vetted?("some", nil, nil), "a legacy row counts as human"
      assert Assessments::CarriedCell.vetted?("some", "seeded", "occasional")
      assert_not Assessments::CarriedCell.vetted?("some", "seeded", nil)
      assert_not Assessments::CarriedCell.vetted?(nil, "human", "some"), "an agreed cell doesn't rate a side for it"
    end
  end
end
