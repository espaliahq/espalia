# frozen_string_literal: true

# What the Units view marks when it compares two dates (#139): labels on a
# unit, and the people who joined, left or moved through a unit's card.
# NONE marks nothing, so the view renders as today when no date is picked.
class OrgGraph::Comparison
  # One line on a unit's card, such as "Uma Reyes" and "joined 5 Nov".
  PersonChange = Data.define(:name, :text)

  # @param unit [OrgUnit]
  # @return [Array<String>] short labels, such as "new" or "was Insights"
  def unit_marks(unit) = []

  # @param unit [OrgUnit]
  # @return [Array<PersonChange>] the people who joined, left or moved through the unit directly
  def people_changes(unit) = []

  # @return [String, nil] the heading above a card's people changes, such as "Since 1 Oct"
  def window_label = nil

  NONE = new.freeze
end
