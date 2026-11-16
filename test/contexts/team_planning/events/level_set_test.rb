# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::LevelSetTest < ActiveSupport::TestCase
  should "refuse no level from an editor, and keep one followed from the Org Graph as cleared" do
    [ nil, "", "  " ].each do |level|
      assert_raises(TeamPlanning::Error, level.inspect) { TeamPlanning::Events::LevelSet.end_state({ level: }) }
      assert_equal({ level: TeamPlanning::Events::LevelSet::CLEARED }, TeamPlanning::Events::LevelSet.followed_end_state({ level: }))
    end
    assert_equal({ level: "5" }, TeamPlanning::Events::LevelSet.followed_end_state({ level: " 5 " }))
  end

  should "read a cleared level as no level when comparing, and a forgotten one as never cleared" do
    cleared = Shreddable::Value.new(TeamPlanning::Events::LevelSet::CLEARED)
    assert TeamPlanning::Events::LevelSet.cleared?(cleared)
    assert TeamPlanning::Events::LevelSet.same_end_state?({ level: cleared }, { level: nil })
    assert_not TeamPlanning::Events::LevelSet.cleared?(Shreddable::Value.removed)
    assert_not TeamPlanning::Events::LevelSet.cleared?(nil)
  end
end
