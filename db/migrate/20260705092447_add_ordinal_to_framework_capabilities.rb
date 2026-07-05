# frozen_string_literal: true

class AddOrdinalToFrameworkCapabilities < ActiveRecord::Migration[8.1]
  def change
    add_column :framework_capabilities, :ordinal, :integer
  end
end
