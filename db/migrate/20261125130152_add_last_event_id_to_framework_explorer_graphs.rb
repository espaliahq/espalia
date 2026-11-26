# frozen_string_literal: true

class AddLastEventIdToFrameworkExplorerGraphs < ActiveRecord::Migration[8.1]
  def change
    add_column :framework_explorer_graphs, :last_event_id, :uuid
  end
end
