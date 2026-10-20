# frozen_string_literal: true

# The header's "N pending" badge on the Activity toggle.
#
# Lives OUTSIDE the context pane's Turbo Frame, so it used to go stale the
# moment a suggestion landed — the feed updated live off the `framework_activity`
# broadcast while the badge kept its page-load value until a full reload. It now
# rides the same broadcast: {Frameworks::Projections::BroadcastsFrameworkActivity}
# replaces this element alongside the pane's sync signal, so header and pane
# agree within one broadcast.
#
# Always rendered (empty at zero) so the broadcast always has a target.
#
class Views::Frameworks::Explorer::PendingCountBadge < Views::Base
  BADGE_ID = "framework-pending-badge"

  # @param count [Integer] pending *proposals* — an open clarification is a
  #   discussion, not a pending change, and never inflates this badge.
  def initialize(count:)
    @count = count.to_i
  end

  def view_template
    span(id: BADGE_ID) do
      if @count.positive?
        render Components::Kit::Badge.new("#{@count} pending", tone: :warning)
      end
    end
  end
end
