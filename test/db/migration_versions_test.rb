# frozen_string_literal: true

require "test_helper"

# Parallel lanes each typed a "round" version (…070000, …080000) and picked the
# same one. Rails refuses a duplicate at boot, but only once both files meet on
# one branch, usually main after the second merge. A generated version can't collide.
class MigrationVersionsTest < ActiveSupport::TestCase
  # Versions up to here predate the rule and stay as they are.
  LAST_HAND_TYPED = "20261114120000"

  should "take a generated version for each new migration" do
    hand_typed = versions.select { |v| v > LAST_HAND_TYPED && v.end_with?("0000", "0001", "0002") }

    assert_empty hand_typed, <<~MSG
      #{hand_typed.join(', ')} looks typed by hand, at the top of an hour, where other lanes
      pick the same version. Create migrations with `bin/rails g migration <Name>` so the
      version is the time to the second.
    MSG
  end

  private

  def versions
    Dir[Rails.root.join("db/migrate/*.rb")].map { |path| File.basename(path)[/\A\d+/] }
  end
end
