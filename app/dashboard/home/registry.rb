# frozen_string_literal: true

# Registry of Home dashboard cards.
#
# Order in {CARDS} is not significant — rendered instances are sorted by
# descending priority (then title) so the most urgent card surfaces first.
# Adding a card to the Home page is "write a {Home::Card} subclass + add it
# here"; no other wiring.
module Home::Registry
  CARDS = [
    Home::AwaitingYouCard,
    Home::CycleProgressCard,
    Home::AssessmentProgressCard,
    Home::RecentActivityCard
  ].freeze

  module_function

  # All renderable card instances for a viewer, most-urgent first.
  # @param context [AuthorizationContext]
  # @return [Array<Home::Card::Instance>]
  def instances_for(context)
    CARDS
      .select { |card| card.audience?(context) }
      .flat_map { |card| card.instances(context) }
      .sort_by { |instance| [ -instance.priority, instance.title.to_s ] }
  end

  # Look up a card class by its stable key.
  # @param key [String]
  # @return [Class<Home::Card>, nil]
  def find(key)
    CARDS.find { |card| card.key == key }
  end
end
