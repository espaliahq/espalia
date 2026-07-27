# frozen_string_literal: true

# A resolved clarification can link the concrete change suggestion its
# discussion spawned ("reworded L4 — see suggestion …").
class AddResultingSuggestionToFrameworkSuggestedEdits < ActiveRecord::Migration[8.1]
  def change
    add_column :framework_suggested_edits, :resulting_suggestion_id, :uuid
  end
end
