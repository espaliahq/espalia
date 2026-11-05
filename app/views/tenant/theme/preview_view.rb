# frozen_string_literal: true

# A small page in one theme and scheme: the navbar, and a card with a badge and the main
# action. The Theme page frames one per preset and scheme, so each shows its real roles.
class Views::Tenant::Theme::PreviewView < Views::Base
  # @param tenant [Tenant]
  def initialize(tenant:)
    @tenant = tenant
  end

  def view_template
    render Components::Shell::Navbar.new(app_name: product_name, current_tenant: @tenant)
    div(class: "p-4") do
      render Components::Kit::Card.new(title: "Quarterly check-in") do |card|
        card.body do
          p(class: "text-sm text-muted") { "Two capabilities left to confirm." }
          div(class: "mt-4 flex flex-wrap items-center justify-between gap-3") do
            render Components::Kit::Badge.new("In progress", variant: :primary)
            render Components::Kit::Button.new(tone: :brand, data: { theme_preview_button: true }) { "Confirm" }
          end
        end
      end
    end
  end
end
