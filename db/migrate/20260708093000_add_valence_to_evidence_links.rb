# frozen_string_literal: true

class AddValenceToEvidenceLinks < ActiveRecord::Migration[8.1]
  def change
    # Nullable by design: links created before valence existed carry no
    # valence forever (events are immutable, intent can't be backfilled).
    add_column :evidence_links, :valence, :string
  end
end
