# frozen_string_literal: true

# The framework-wide deficit tolerance defaults to 0.75 (ADR-21): a
# current-level "not yet" (deficit 1.0) blocks, "some" and "most of the time"
# can still be made up elsewhere. At 1.0 the gate could never fire — a
# capability's current-level deficit maxes out at exactly 1.0.
#
# The default now lives in ONE place — `PersonDevelopment::Scoring::
# DEFAULT_DEFICIT_THRESHOLD` — and the column carries nil for "system
# default", like the three ratio thresholds. So the column loses its database
# default and its NOT NULL, and the data fix is scoped by the event stream: a
# row still on the old column default whose framework never configured a
# tolerance becomes nil, which is exactly what a `reset!` + replay reproduces
# (`FrameworkCreated` sets no tolerance; `ScoringThresholdsConfigured`
# carries whatever was configured, so a configured 1.0 is left alone — the
# projection's own round-trip invariant, event-sourcing.md).
class LowerDefaultDeficitThreshold < ActiveRecord::Migration[8.1]
  class FrameworkStateRow < ActiveRecord::Base
    self.table_name = "framework_states"
  end

  CONFIGURED_EVENT = "Frameworks::Events::ScoringThresholdsConfigured"

  def up
    change_column_default :framework_states, :deficit_threshold, from: 1.0, to: nil
    change_column_null :framework_states, :deficit_threshold, true

    FrameworkStateRow
      .where(deficit_threshold: 1.0)
      .where.not(framework_id: frameworks_with_a_configured_tolerance)
      .update_all(deficit_threshold: nil)
  end

  def down
    FrameworkStateRow.where(deficit_threshold: nil).update_all(deficit_threshold: 1.0)
    change_column_null :framework_states, :deficit_threshold, false
    change_column_default :framework_states, :deficit_threshold, from: nil, to: 1.0
  end

  private

  # Frameworks whose stream carries an explicit tolerance — their row is the
  # projection's, not the column default's, and a replay reproduces it.
  def frameworks_with_a_configured_tolerance
    select_values("SELECT data::text FROM event_store_events WHERE event_type = #{quote(CONFIGURED_EVENT)}")
      .filter_map do |payload|
        data = JSON.parse(payload)
        data["framework_id"] unless data["deficit_threshold"].nil?
      end
      .uniq
  end
end
