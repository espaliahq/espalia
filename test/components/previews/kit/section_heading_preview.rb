# frozen_string_literal: true

# @label Section heading
class Kit::SectionHeadingPreview < Lookbook::Preview
  # @param title text
  # @param subtitle text
  # @param tag select { choices: [h2, h3, h4] }
  # @param with_action toggle
  def playground(title: "Role families", subtitle: "7 families, 11 roles", tag: :h2, with_action: false)
    render Components::Kit::SectionHeading.new(title, subtitle: subtitle.presence, tag: tag.to_sym) do |heading|
      if with_action
        heading.action do
          heading.a(href: "#", class: "text-sm font-medium text-primary-ink") { "View all" }
        end
      end
    end
  end

  # @!group Tags

  def h2
    render Components::Kit::SectionHeading.new(
      "Feedback export",
      subtitle: "Download every piece of feedback in a cycle as a CSV file for reporting."
    )
  end

  def h3
    render Components::Kit::SectionHeading.new("Capabilities", subtitle: "40 capabilities across 6 categories", tag: :h3)
  end

  def h4
    render Components::Kit::SectionHeading.new("Behavioural expectations", subtitle: "One per capability and level", tag: :h4)
  end

  # @!endgroup

  # @!group States

  def without_subtitle
    render Components::Kit::SectionHeading.new("People")
  end

  def with_action
    render Components::Kit::SectionHeading.new("Capabilities", subtitle: "40 capabilities") do |heading|
      heading.action do
        heading.a(href: "#", class: "text-sm font-medium text-primary-ink") { "View all" }
      end
    end
  end

  def long_title_with_action
    render Components::Kit::SectionHeading.new(
      "Configuration for the HiBob integration that keeps people, roles and levels in sync",
      subtitle: "Read-only view of the HRIS configuration for this workspace. Changes are made by a platform admin."
    ) do |heading|
      heading.action do
        heading.a(href: "#", class: "text-sm font-medium text-primary-ink") { "Sync now" }
      end
    end
  end

  # @!endgroup
end
