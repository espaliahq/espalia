# frozen_string_literal: true

# Which kind of endpoint produced a suggestion, beside the model id and the
# prompt version, so an eval or an audit can tell a gateway run from a direct one.
# Every row stored before this column came from the Anthropic API.
class AddProviderToEvidencePlacementSuggestions < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_placement_suggestions, :provider, :string, null: false, default: "anthropic"
    change_column_default :evidence_placement_suggestions, :provider, from: "anthropic", to: nil
  end
end
