# frozen_string_literal: true

# @label Chip
class Kit::ChipPreview < Lookbook::Preview
  Chip = Components::Kit::Chip

  # @param label text
  # @param pressed toggle
  # @param removable toggle
  # @param disabled toggle
  # @param size select [md, sm]
  def playground(label: "This cycle", pressed: false, removable: false, disabled: false, size: :md)
    render Chip.new(label, pressed: pressed, remove: ({} if removable), disabled: disabled, size: size.to_sym)
  end

  # Small toggles for a dense row, such as level headings over a scale
  def small
    render_with_template(locals: { levels: %w[E1 E2 E3 E4 E5], selected: "E3" })
  end

  # Rest, selected, and each disabled, on a card and on the page. Hover and focus with the pointer and Tab.
  def toggle_states
    render_with_template
  end

  # A row of filters, one selected
  def toggle_group
    render_with_template(locals: { periods: [ "This week", "This cycle", "All time" ], selected: "This cycle" })
  end

  # Removable people: the × is a 44px target named "Remove <name>"
  def removable
    render_with_template(locals: { people: [ "Aisha Khan", "Ben Ito", "Chloé Martin" ] })
  end
end
