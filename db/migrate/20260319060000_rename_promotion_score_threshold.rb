# frozen_string_literal: true

class RenamePromotionScoreThreshold < ActiveRecord::Migration[8.1]
  def change
    rename_column :framework_states, :promotion_score_threshold, :meeting_expectation_threshold
  end
end
