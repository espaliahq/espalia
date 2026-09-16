# frozen_string_literal: true

# The framework-wide deficit tolerance defaults to 0.75 (ADR-21): a
# current-level "not yet" (deficit 1.0) blocks, "some" and "most of the time"
# can still be made up elsewhere. At 1.0 the gate could never fire — a
# capability's current-level deficit maxes out at exactly 1.0.
#
# The column is NOT NULL with a database default (a never-configured framework
# carries the default, not an event), so the default moves here and rows still
# on the old default follow it. A framework that explicitly configured 1.0 is
# restored by the projection on its next rebuild (the event carries the value).
class LowerDefaultDeficitThreshold < ActiveRecord::Migration[8.1]
  class FrameworkStateRow < ActiveRecord::Base
    self.table_name = "framework_states"
  end

  def up
    change_column_default :framework_states, :deficit_threshold, from: 1.0, to: 0.75
    FrameworkStateRow.where(deficit_threshold: 1.0).update_all(deficit_threshold: 0.75)
  end

  def down
    change_column_default :framework_states, :deficit_threshold, from: 0.75, to: 1.0
    FrameworkStateRow.where(deficit_threshold: 0.75).update_all(deficit_threshold: 1.0)
  end
end
