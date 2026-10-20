# frozen_string_literal: true

# @label To confirm chip
class Kit::ToConfirmChipPreview < Lookbook::Preview
  # @param label text
  # @param title text
  # @param compact toggle
  def playground(label: "3 to confirm",
                 title: "Carried from the last cycle — confirm each one or change it to complete the assessment",
                 compact: false)
    render Components::Kit::ToConfirmChip.new(label, title: title, compact: compact)
  end

  # @!group Sizes

  # The assessment's status pill
  def default
    render Components::Kit::ToConfirmChip.new(
      "3 to confirm",
      title: "Carried from the last cycle — confirm each one or change it to complete the assessment"
    )
  end

  # Beside the other chips on a capability's name row
  def compact
    render Components::Kit::ToConfirmChip.new(
      "To confirm", compact: true,
      title: "Carried from the last cycle — pick the same value to confirm it, or change it"
    )
  end

  # @!endgroup
end
