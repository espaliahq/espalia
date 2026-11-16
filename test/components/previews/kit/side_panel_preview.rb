# frozen_string_literal: true

# @label Side panel
class Kit::SidePanelPreview < Lookbook::Preview
  # @param open toggle
  # @param narrow select { choices: [overlay, stack] }
  def playground(open: true, narrow: :overlay)
    side_panel(id: "playground-panel", open:, narrow: narrow.to_sym)
  end

  # @!group States

  # Open beside the main column; below lg it overlays the page
  def open_overlay
    side_panel(id: "open-overlay-panel", open: true, narrow: :overlay)
  end

  # Closed, so the main column takes the full width
  def closed
    side_panel(id: "closed-panel", open: false, narrow: :overlay)
  end

  # Below lg it sits under the main column instead
  def open_stack
    side_panel(id: "open-stack-panel", open: true, narrow: :stack)
  end

  # @!endgroup

  private

  def side_panel(id:, open:, narrow:)
    render Components::Kit::SidePanel.new(id:, title: "About this plan", open:, narrow:,
                                          cookie: "lookbook_#{id.underscore}_open", url_key: id) do |panel|
      panel.main do
        panel.div(class: "mb-4 flex items-center justify-between gap-3") do
          panel.h2(class: "text-base font-semibold text-default") { "Scenarios" }
          panel.toggle
        end
        panel.div(class: "rounded-lg border border-dashed border-emphasized p-10 text-sm text-muted") do
          "Two scenarios: Next quarter and Hiring freeze. The map takes this column's full width when the panel is closed."
        end
      end
      panel.body do
        panel.render Components::Kit::Card.new(title: "Rules") do |card|
          card.body { card.p(class: "text-sm text-muted") { "Every unit keeps one manager per eight people." } }
        end
        panel.render Components::Kit::Card.new(title: "Members") do |card|
          card.body { card.p(class: "text-sm text-muted") { "Three members: two editors and a viewer." } }
        end
      end
    end
  end
end
