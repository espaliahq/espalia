# frozen_string_literal: true

# The explorer's ONE write-feedback region — a persistent `role="status"` live
# region in the explorer shell that every edit-mode write updates via Turbo
# Stream ("Saved", "Proposed for review", "Archived", …).
#
# Before this, "I changed something" had seven different outcomes: a silent
# frame swap, a full page reload with a Rails flash, a whole-matrix re-fetch,
# or nothing at all. One region, one vocabulary, and — because the region
# itself never leaves the DOM — assistive tech announces each message without
# the live region having to be re-created (which suppresses announcement).
#
# The container is rendered once by {Views::Frameworks::ShowView}; controllers
# push messages into it with `turbo_stream.update(WriteStatus::REGION_ID, …)`
# carrying a {Views::Frameworks::Explorer::WriteStatus::Message}.
#
class Views::Frameworks::Explorer::WriteStatus < Views::Base
  REGION_ID = "framework-write-status"

  def view_template
    div(
      id: REGION_ID,
      role: "status",
      aria_live: "polite",
      aria_atomic: "true",
      # Bottom-right, not the layout flash's `top-4 right-4`. This region fires
      # on EVERY write, so unlike a once-per-navigation flash it cannot afford
      # to cover anything the user acts on: at `top-4` it sits over the navbar's
      # notification bell and account menu, and at `top-16` over the framework
      # header's Publish button — for four seconds, every time. The explorer's
      # bottom-right is the only corner holding nothing but content.
      class: "fixed bottom-4 right-4 z-50 flex flex-col gap-2 pointer-events-none"
    ) { }
  end
end
