# frozen_string_literal: true

class AddUnderperformingThresholdToFrameworkStateFrameworks < ActiveRecord::Migration[8.1]
  def change
    add_column :framework_states, :underperforming_threshold,
               :decimal, precision: 5, scale: 2
  end
end
