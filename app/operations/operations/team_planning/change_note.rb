# frozen_string_literal: true

# Whether a reader may see a change's note. A note is free text, so one on a
# pay change may state an amount: it reaches only a member with the see-pay
# right, and anyone else gets no note at all, not even a sign one exists
# ([#292](https://github.com/espaliahq/espalia/issues/292)). Every read that
# returns a note asks this.
module Operations::TeamPlanning::ChangeNote
  # @param note [Shreddable::Value, nil] as the read model holds it
  # @param facet [String, nil] the facet of the change it notes
  # @param see_pay [Boolean] whether the reader holds the see-pay right
  # @return [Hash, nil] `{ value: }` or `{ removed: true }`, or nil when there is none to show
  def self.payload(note, facet:, see_pay:)
    return nil unless visible?(facet, see_pay:)

    Operations::TeamPlanning::MapPayload.sealed(note)
  end

  # @param facet [String, nil]
  # @param see_pay [Boolean]
  # @return [Boolean]
  def self.visible?(facet, see_pay:) = !hidden_facets(see_pay:).include?(facet)

  # @param see_pay [Boolean]
  # @return [Array<String>] the facets whose notes this reader may not see
  def self.hidden_facets(see_pay:) = see_pay ? [] : [ ::TeamPlanning::Events::PlanDataSet::PAY_FACET ]
end
