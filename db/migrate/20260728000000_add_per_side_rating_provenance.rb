# frozen_string_literal: true

class AddPerSideRatingProvenance < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_level_ratings, :self_rating_source, :string
    add_column :assessment_level_ratings, :manager_rating_source, :string
  end
end
