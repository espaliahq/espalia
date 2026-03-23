# frozen_string_literal: true

class AddScoringThresholdsToFrameworks < ActiveRecord::Migration[8.1]
  def change
    # Framework-level scoring thresholds — can be overridden at category/binding level.
    add_column :framework_states, :overperformance_cap, :integer, null: false, default: 1
    add_column :framework_states, :deficit_threshold, :decimal, precision: 5, scale: 2, null: false, default: 1.0

    # Category-level overrides (nullable = inherit from framework).
    add_column :framework_capability_categories, :overperformance_cap, :integer, null: true
    add_column :framework_capability_categories, :deficit_threshold, :decimal, precision: 5, scale: 2, null: true

    # Binding-level overrides: deficit_threshold replaces individual_tolerance.
    # overperformance_cap is new.
    add_column :framework_capability_role_bindings, :overperformance_cap, :integer, null: true
    add_column :framework_capability_role_bindings, :deficit_threshold, :decimal, precision: 5, scale: 2, null: true
    remove_column :framework_capability_role_bindings, :individual_tolerance, :decimal
  end
end
