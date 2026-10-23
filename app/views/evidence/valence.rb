# frozen_string_literal: true

# Shared surface vocabulary for evidence-link valence — the one place UI
# labels and badge styling for {EvidenceLink::VALENCES} live. Domain values
# are frozen (they live in immutable events); these labels are free to
# change.
#
# Colour discipline: these badges must never read as the frequency-rating
# palette (red / yellow / green / blue = ratings everywhere in the app).
# Valence uses emerald / amber / rose tints with the text label always
# present — colour is reinforcement, never the sole signal.
module Views::Evidence::Valence
  LABELS = {
    "strongly_demonstrated" => "Strongly demonstrates",
    "demonstrated" => "Demonstrates",
    "growth_area" => "Growth area",
    "significant_growth_area" => "Significant growth area"
  }.freeze

  BADGE_CLASSES = {
    "strongly_demonstrated" => "bg-valence-strongly-demonstrated text-valence-strongly-demonstrated",
    "demonstrated" => "bg-valence-demonstrated text-valence-demonstrated",
    "growth_area" => "bg-valence-growth-area text-valence-growth-area",
    "significant_growth_area" => "bg-valence-significant-growth-area text-valence-significant-growth-area"
  }.freeze

  # Ordered [label, value] pairs for selects / radio groups.
  OPTIONS = EvidenceLink::VALENCES.map { |value| [ LABELS.fetch(value), value ] }.freeze

  # @param valence [String, nil]
  # @return [String, nil] the UI label, nil for unclassified (historical) links
  def valence_label(valence)
    LABELS[valence]
  end

  # Renders the small valence badge (no-op for unclassified links).
  #
  # @param valence [String, nil]
  def valence_badge(valence)
    label = LABELS[valence]
    return unless label

    span(class: "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium #{BADGE_CLASSES[valence]}",
         data: { valence: valence }) { label }
  end
end
