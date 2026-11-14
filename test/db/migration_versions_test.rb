# frozen_string_literal: true

require "test_helper"

# Parallel lanes each typed a "round" version (…070000, …080000) and picked the
# same one. Rails refuses a duplicate at boot, but only once both files meet on
# one branch, usually main after the second merge. A generated version can't collide.
class MigrationVersionsTest < ActiveSupport::TestCase
  # Versions up to here predate the rule and stay as they are.
  LAST_HAND_TYPED = "20261114120000"

  # The minutes and seconds lanes type: 0000-0009, and any five minutes on the
  # dot (0500, 1500, 3000…). A generated version ends like that 1 time in 300.
  HAND_TYPED = /(000\d|[0-5][05]00)\z/

  should "take a generated version for each new migration" do
    hand_typed = versions.select { |v| v > LAST_HAND_TYPED && (v.match?(HAND_TYPED) || v > in_a_day) }

    assert_empty hand_typed, <<~MSG
      #{hand_typed.join(', ')} looks typed by hand: a round time, or one in the future, where
      other lanes pick the same version. Create migrations with `bin/rails g migration <Name>`.
      If the generator chose it, run it again a minute later.
    MSG
  end

  private

  def in_a_day = 1.day.from_now.utc.strftime("%Y%m%d%H%M%S")

  def versions
    Dir[Rails.root.join("db/migrate/*.rb")].map { |path| File.basename(path)[/\A\d+/] }
  end
end
