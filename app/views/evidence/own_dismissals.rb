# frozen_string_literal: true

# Under a piece of feedback on the hub, the suggestions the viewer dismissed:
# "You dismissed the suggestion for Ownership · E3 on 27 Nov", and the reason
# if they gave one. Only the viewer's own ({Evidence::OwnDismissals}).
#
# Rendered with the same id, empty or not, by the hub and by the dismiss
# response, which replaces it.
class Views::Evidence::OwnDismissals < Views::Base
  include Views::Evidence::ConversationChrome

  # @param item_id [String]
  # @return [String]
  def self.dom_id_for(item_id) = "evidence-own-dismissals-#{item_id}"

  # @param item [EvidenceItem]
  # @param dismissals [Array<EvidencePlacementSuggestion>] the viewer's, oldest first
  # @param cells [Hash{String => Hash}] suggestion id => { name:, level_code: }
  def initialize(item:, dismissals:, cells: {})
    @item = item
    @dismissals = dismissals
    @cells = cells
  end

  def view_template
    div(id: self.class.dom_id_for(@item.id), data: { testid: "own-dismissals" }) do
      next if @dismissals.empty?

      ul(class: "mt-2 space-y-1.5", role: "list") { @dismissals.each { |dismissal| line(dismissal) } }
    end
  end

  private

  def line(dismissal)
    li(class: "text-xs text-muted") do
      p { "You dismissed the suggestion for #{cell_label(dismissal)} #{when_phrase(dismissal.decided_at)}." }
      reason = Prose.to_plain(dismissal.dismiss_reason.to_s).presence
      p(class: "text-default") { "Your reason: “#{reason}”" } if reason
    end
  end

  def cell_label(dismissal)
    cell = @cells.fetch(dismissal.id, {})
    [ cell[:name] || "a capability", cell[:level_code].presence || "L#{dismissal.level_ordinal}" ].join(" · ")
  end

  def when_phrase(time)
    date = short_date(time)
    return "" if date.empty?

    date == "Today" ? "today" : "on #{date}"
  end
end
