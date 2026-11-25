# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::SuggestionCollisionTest < ActiveSupport::TestCase
  STATUSES = EvidencePlacementSuggestion::STATUSES

  def resolve(retiring, survivor) = PersonDevelopment::SuggestionCollision.resolve(retiring: retiring, survivor: survivor)

  should "move a suggestion when its new cell is free" do
    STATUSES.each { |status| assert_equal :move, resolve(status, nil) }
  end

  should "keep a dismissal, whichever side of the collision it is on" do
    STATUSES.each do |other|
      assert_equal :keep_survivor, resolve(other, "dismissed"), "#{other} onto dismissed"
      expected = other == "dismissed" ? :keep_survivor : :replace_survivor
      assert_equal expected, resolve("dismissed", other), "dismissed onto #{other}"
    end
  end

  should "keep a decision over an open suggestion, and the survivor's on a tie" do
    assert_equal :replace_survivor, resolve("accepted", "pending")
    assert_equal :replace_survivor, resolve("edited", "superseded")
    assert_equal :keep_survivor, resolve("pending", "accepted")
    assert_equal :keep_survivor, resolve("accepted", "edited")
    assert_equal :keep_survivor, resolve("pending", "superseded")
  end
end
