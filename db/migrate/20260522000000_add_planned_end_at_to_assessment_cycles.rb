# frozen_string_literal: true

class AddPlannedEndAtToAssessmentCycles < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycles, :planned_end_at, :date
  end
end
