# frozen_string_literal: true

# @label Card
class Kit::CardPreview < Lookbook::Preview
  # @param title text
  # @param variant select { choices: [default, flush] }
  # @param heading_level select { choices: [h2, h3, h4] }
  # @param with_actions toggle
  def playground(title: "Assessment cycle", variant: :default, heading_level: :h3, with_actions: true)
    render Components::Kit::Card.new(
      title: title.presence, variant: variant.to_sym, heading_level: heading_level.to_sym
    ) do |card|
      card.body do
        card.p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "H2 2026 performance review runs from 1 November to 13 December. 42 people are enrolled."
        end
      end
      if with_actions
        card.actions do
          card.a(href: "#", class: "text-sm font-medium text-primary-ink") { "View cycle" }
        end
      end
    end
  end

  # @!group Variants

  def with_title
    render Components::Kit::Card.new(title: "Tenant role") do |card|
      card.body do
        card.p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "Admins can edit frameworks, run assessment cycles and manage people."
        end
      end
    end
  end

  def without_title
    render Components::Kit::Card.new do |card|
      card.body do
        card.p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "No assessment cycles yet. Start one to collect self-assessments and manager ratings."
        end
      end
    end
  end

  def with_actions
    render Components::Kit::Card.new(title: "Download H2 2026 performance review") do |card|
      card.body do
        card.p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "128 pieces of feedback from 42 people, as a CSV file."
        end
      end
      card.actions do
        card.a(href: "#", class: "text-sm font-medium text-gray-600 dark:text-gray-300") { "Cancel" }
        card.a(href: "#", class: "text-sm font-medium text-primary-ink") { "Download CSV" }
      end
    end
  end

  def flush_with_table
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        card.table(class: "min-w-full divide-y divide-gray-200 dark:divide-gray-700") do
          card.thead(class: "bg-gray-50 dark:bg-gray-900") do
            card.tr do
              %w[Person Role Level].each do |heading|
                card.th(class: "px-6 py-3 text-left text-xs font-medium text-gray-600 dark:text-gray-300 uppercase tracking-wide") { heading }
              end
            end
          end
          card.tbody(class: "divide-y divide-gray-200 dark:divide-gray-700") do
            [
              [ "Priya Shah", "Software Engineer", "L3" ],
              [ "Tom Nguyen", "Engineering Manager", "M2" ],
              [ "Aisha Okafor", "Product Designer", "L4" ]
            ].each do |row|
              card.tr do
                row.each do |cell|
                  card.td(class: "px-6 py-4 text-sm text-gray-900 dark:text-white") { cell }
                end
              end
            end
          end
        end
      end
    end
  end

  def flush_with_title
    render Components::Kit::Card.new(title: "People in this cycle", variant: :flush) do |card|
      card.body do
        card.ul(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          [ "Priya Shah", "Tom Nguyen", "Aisha Okafor" ].each do |name|
            card.li(class: "px-6 py-3 text-sm text-gray-900 dark:text-white") { name }
          end
        end
      end
    end
  end

  def long_title
    render Components::Kit::Card.new(
      title: "Feedback requested from your manager, two peers and one direct report for the H2 2026 performance review"
    ) do |card|
      card.body do
        card.p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "Three of four people have responded. Reminders go out every Monday until the cycle closes."
        end
      end
    end
  end

  def title_only
    render Components::Kit::Card.new(title: "Brand colours")
  end

  # @!endgroup
end
