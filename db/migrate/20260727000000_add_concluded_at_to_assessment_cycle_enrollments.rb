# frozen_string_literal: true

class AddConcludedAtToAssessmentCycleEnrollments < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycle_enrollments, :concluded_at, :datetime
  end
end
