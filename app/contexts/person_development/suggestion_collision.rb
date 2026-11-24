# frozen_string_literal: true

# Which suggestion keeps a cell when a framework migration moves one onto a
# cell where the same evidence item already has another. The aggregate and the
# {PersonDevelopment::Projections::EvidenceSuggestions} projection both ask
# here, so the stream and the table can't keep different rows.
#
# A dismissal always survives: it is what stops the model proposing the cell
# again. Then a decision beats an open suggestion. A tie keeps the survivor's.
module PersonDevelopment::SuggestionCollision
  RANK = { "dismissed" => 2, "accepted" => 1, "edited" => 1 }.freeze

  # @param retiring [String] the moving suggestion's status
  # @param survivor [String, nil] the status of the one already at the cell, nil when none
  # @return [Symbol] :move (no collision), :keep_survivor, or :replace_survivor
  def self.resolve(retiring:, survivor:)
    return :move if survivor.nil?

    RANK.fetch(retiring, 0) > RANK.fetch(survivor, 0) ? :replace_survivor : :keep_survivor
  end
end
