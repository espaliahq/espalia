# frozen_string_literal: true

# Archive is reversible state on a closed session, written by the
# CalibrationSessions projection from CalibrationSessionArchived /
# CalibrationSessionUnarchived. New events with no history, so no rebuild.
class AddArchivedToCalibrationSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :calibration_sessions, :archived_at, :datetime
    add_column :calibration_sessions, :archived_by_id, :uuid
  end
end
