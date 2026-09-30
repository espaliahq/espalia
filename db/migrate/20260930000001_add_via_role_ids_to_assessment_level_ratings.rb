# frozen_string_literal: true

# Where a rating was made, for provenance only (ADR-22): the role whose cells
# the rater was reading through a lens, nil for the home role. A rating is a
# fact about the cell whichever role it was read through, so no reader scopes
# by these columns; the activity feed names the lens ("while exploring PM3").
#
# Nil on every existing row, which is also what a replay produces: no event
# carried the field before it existed, so the projection needs no rebuild.
class AddViaRoleIdsToAssessmentLevelRatings < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_level_ratings, :self_rated_via_role_id, :uuid
    add_column :assessment_level_ratings, :manager_rated_via_role_id, :uuid
  end
end
