# frozen_string_literal: true

# A decision model (TypeSafe AI's Jev) answers with a cell and a probability
# and writes no prose, so a suggestion's rationale is optional.
class AllowNullRationaleOnEvidencePlacementSuggestions < ActiveRecord::Migration[8.1]
  def up
    change_column_null :evidence_placement_suggestions, :rationale, true
  end

  # Jev's rows have no rationale; they come back with an empty one.
  def down
    change_column_null :evidence_placement_suggestions, :rationale, false, ""
  end
end
