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
  # Sized to sit beside the other chips on a capability's name row.
  COMPACT_CLASSES = "inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium " \
                    "border border-dashed border-amber-500 dark:border-amber-400 " \
                    "text-amber-800 dark:text-amber-300"

  # @param label [String]
  # @param title [String, nil] the tooltip that says what confirming means
  # @param compact [Boolean] the name-row size
  def initialize(label, title: nil, compact: false)
    @label = label
    @title = title
    @compact = compact
  end

  def view_template
    span(class: @compact ? COMPACT_CLASSES : CLASSES, title: @title) { @label }
  end
end
