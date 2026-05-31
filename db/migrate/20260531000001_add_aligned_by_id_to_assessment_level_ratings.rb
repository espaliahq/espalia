# frozen_string_literal: true

# Records WHICH person recorded the current aligned (agreed) frequency on each
# (cycle, person, capability, level) row. Captured as a domain fact on the
# AssessmentAligned event — for manual alignments the submitter (assessee or
# manager), for auto-aligned cells the manager who started alignment — and
# projected here so read sites can attribute the agreement.
#
# Nullable: cleared on AlignmentCleared, and nil on historical rows aligned
# before attribution shipped.
class AddAlignedByIdToAssessmentLevelRatings < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_level_ratings, :aligned_by_id, :uuid
  end
end
