# frozen_string_literal: true

# Where hiring for an open position stands, as the scenario map and the
# timeline label it ([#458](https://github.com/espaliahq/espalia/issues/458)):
# "Recruiting · starts 1 Jun 2026", or "On hold". Not started goes unsaid, as
# every open seat starts there.
class Views::Plans::HiringNote < Views::Base
  STATUSES = { "recruiting" => "Recruiting", "on_hold" => "On hold", "offer_accepted" => "Offer accepted" }.freeze

  # @param position [Hash] a position from the map or timeline payload
  # @return [String, nil]
  def self.text(position)
    status = STATUSES[position[:hiring_status]]
    return status if position[:hiring_status] == "on_hold"

    start = position[:target_start].presence && "starts #{Date.iso8601(position[:target_start].to_s).strftime('%-d %b %Y')}"
    [ status, start ].compact.join(" · ").upcase_first.presence
  end

  # @param position [Hash]
  def initialize(position)
    @text = self.class.text(position)
  end

  def view_template
    span(data: { hiring_note: "" }, class: "text-muted") { @text } if @text
  end
end
