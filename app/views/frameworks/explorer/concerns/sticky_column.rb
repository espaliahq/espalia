# frozen_string_literal: true

# Shared styling for the matrix's sticky capability column.
#
# == THE OPACITY INVARIANT (NON-NEGOTIABLE)
#
# Every `position: sticky` cell in the matrix MUST have a fully opaque
# background in BOTH themes — hover and focus variants included. A sticky cell
# is a mask: content scrolls underneath it, and a translucent background
# (`bg-…/NN`) or a missing one lets that content render straight through.
#
# This is not theoretical. `bg-blue-50/30 dark:bg-blue-900/10` on the expanded
# row's sticky cell put a whole column of illustration text where the
# capability column should be (issue #371), and the same shape lurked in the
# compact row's `dark:group-hover:bg-gray-800/50`, which only bled while
# hovering in dark mode.
#
# Where the design calls for a tint, use the OPAQUE COMPOSITE rather than the
# translucent token — the literal hex of that tint over the surface behind it,
# so the cell looks identical but actually masks. Derive it by compositing in
# the browser rather than by eye; the current values are recorded at their call
# sites with the token and surface they came from.
#
# See docs/guidelines/framework-explorer.md → "Sticky Positioning".
module Views::Frameworks::Explorer::Concerns::StickyColumn
  # Right-edge treatment for the sticky column: a slim shadow that reads as
  # "content passes beneath this", so text clipping at the boundary looks
  # deliberate rather than broken.
  #
  # Applied to every cell that IS the column — the header corner, the compact
  # row's capability cell, the expanded row's gutter, and the edit-mode
  # "+ Add capability" cell — so its edge is continuous down the table.
  #
  # DELIBERATELY NOT applied to the one full-width band that also carries
  # `sticky left-0`: the category header. It is `colspan`-the-whole-table
  # (measured: 1704px against the column's 203px), so its right edge is the
  # table's outer edge, not the column boundary — a shadow there would draw a
  # stray line down the far side of the matrix. It interrupts the column's edge
  # by design, being a band across it rather than a cell in it. It still owes
  # the opacity invariant above, and satisfies it (`bg-gray-100
  # dark:bg-gray-800`).
  #
  # The "+ Add capability" row used to be such a band too. It is now a single
  # cell in the capability column — the column it adds to — because a centred
  # label in a matrix-wide row lands off-screen at the default horizontal
  # scroll (#380), so it takes the edge treatment like every other cell in the
  # column.
  #
  # A component class, not a pair of arbitrary-value shadow utilities: this
  # string rode ~100 cells per matrix frame at ~110 bytes each (#383). Defined
  # in app/assets/tailwind/application.css, alongside its dark variant.
  STICKY_EDGE_CLASSES = "mx-sticky-edge"
end
