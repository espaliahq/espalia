# frozen_string_literal: true

# Everyone on one role at one level in a snapshot: how many there were, and
# their median score on each capability and each category, on the hero's
# scale (1.0 is the level met).
class LevelComparisonGroup < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :snapshot, class_name: "LevelComparisonSnapshot", inverse_of: :groups
end
