# frozen_string_literal: true

# Records WHICH manager recorded the current manager rating on each
# (cycle, person, capability, level) row. Captured as a domain fact on the
# ManagerRated/ManagerRatingRevised events and projected here so read sites
# can attribute the rating to a specific person rather than the assessee's
# *current* manager (which can change over time).
#
# Nullable: historical rows (rated before attribution shipped) and
# system-seeded carry-forwards have no human rater.
class AddManagerRatedByIdToAssessmentLevelRatings < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_level_ratings, :manager_rated_by_id, :uuid
  end
end
