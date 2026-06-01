# frozen_string_literal: true

# Turbo Frame wrapper for a single Home card's content.
#
# Rendered by {HomeController#card} (layout: false) in response to a lazy frame
# fetch. The frame id MUST match the placeholder id rendered by
# {Views::Home::DashboardView} so Turbo swaps it in place.
class Views::Home::CardFrame < Views::Base
  # @param dom_id [String] frame id, matching the placeholder
  # @param content [Phlex::HTML] the card's content component
  def initialize(dom_id:, content:)
    @dom_id = dom_id
    @content = content
  end

  def view_template
    turbo_frame_tag(@dom_id) do
      render @content
    end
  end
end
