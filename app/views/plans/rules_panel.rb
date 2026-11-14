# frozen_string_literal: true

# The rules a plan checks its scenarios against (#226). Plans can't set their
# own yet (3.3), so every plan follows the organisation's defaults.
class Views::Plans::RulesPanel < Views::Base
  def view_template
    render Components::Kit::Card.new(title: "Rules", density: :compact) do |card|
      card.body do
        p(class: "text-sm text-muted") { "This plan follows your organisation's defaults." }
      end
    end
  end
end
