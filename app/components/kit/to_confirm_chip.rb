# frozen_string_literal: true

# The dashed amber chip for carried-forward ratings still to confirm. Dashed
# is the carried signal everywhere (pills, level chips), so every surface that
# says "to confirm" wears the same chip.
#
# @example
#   render Components::Kit::ToConfirmChip.new("3 to confirm", title: "…")
#
class Components::Kit::ToConfirmChip < Components::Base
  CLASSES = "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium " \
            "border border-dashed border-amber-500 dark:border-amber-400 " \
            "text-amber-800 dark:text-amber-300"

  # @param label [String]
  # @param title [String, nil] the tooltip that says what confirming means
  def initialize(label, title: nil)
    @label = label
    @title = title
  end

  def view_template
    span(class: CLASSES, title: @title) { @label }
  end
end
