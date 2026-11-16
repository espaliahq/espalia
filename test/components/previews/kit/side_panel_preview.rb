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

  # A toggle in a header above the row, and a body that draws its own heading and close button
  def wrapped_with_own_heading
    render Components::Kit::SidePanel.new(id: "wrapped-panel", title: "Activity", open: true, cookie: "lookbook_wrapped_panel_open",
                                          url_key: "wrapped-panel", heading: false, sticky: true) do |panel|
      panel.main do
        panel.div(class: "rounded-lg border border-dashed border-emphasized p-10 text-sm text-muted") do
          "The matrix takes this column. Its header, with the toggle, sits above the row."
        end
      end
      panel.body do
        panel.div(class: "p-4") do
          panel.div(class: "mb-3 flex items-center justify-between gap-2") do
            panel.h2(class: "text-sm font-semibold text-default") { "Activity" }
            panel.render Components::Kit::SidePanel::Close.new(label: "Close activity", size: :xs, touch: true) { "×" }
          end
          panel.p(class: "text-sm text-muted") { "Alice rated Critical thinking: Most of the time." }
        end
      end
      panel.wrap do
        panel.div(class: "mb-4 flex items-center justify-between gap-3") do
          panel.h2(class: "text-base font-semibold text-default") { "Alice's assessment" }
          panel.render Components::Kit::SidePanel::Toggle.new(controls: "wrapped-panel", open: true, variant: :subtle, compact: true) do
            "Activity"
          end
        end
        panel.columns
      end
    end
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
