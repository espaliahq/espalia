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
  # Applied to the three cells that ARE the column — the header corner, the
  # compact row's capability cell, and the expanded row's gutter — so its edge
  # is continuous down the table.
  #
  # DELIBERATELY NOT applied to the two full-width bands that also carry
  # `sticky left-0`: the category header and the edit-mode "+ Add capability"
  # row. Both are `colspan`-the-whole-table (measured: 1704px against the
  # column's 203px), so their right edge is the table's outer edge, not the
  # column boundary — a shadow there would draw a stray line down the far side
  # of the matrix. They interrupt the column's edge by design, being bands
  # across it rather than cells in it. They still owe the opacity invariant
  # above, and both satisfy it (`bg-white dark:bg-gray-900`, `bg-gray-100
  # dark:bg-gray-800`).
  #
  # Literal class strings — Tailwind's JIT scans source for complete class
  # names and cannot see an interpolated one (Hard-Won Lesson 12).
  STICKY_EDGE_CLASSES =
    "shadow-[6px_0_6px_-6px_rgba(15,23,42,0.25)] dark:shadow-[6px_0_8px_-6px_rgba(0,0,0,0.65)]"
end
