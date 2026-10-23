# frozen_string_literal: true

# @label Badge
class Kit::BadgePreview < Lookbook::Preview
  # @param label text
  # @param variant select { choices: [default, primary, success, warning, info] }
  def playground(label: "Must have", variant: :default)
    render Components::Kit::Badge.new(label, variant: variant.to_sym)
  end

  # @!group Variants

  def default
    render Components::Kit::Badge.new("IC")
  end

  def primary
    render Components::Kit::Badge.new("Must have", variant: :primary)
  end

  def success
    render Components::Kit::Badge.new("Responded", variant: :success)
  end

  def warning
    render Components::Kit::Badge.new("Pending", variant: :warning)
  end

  def info
    render Components::Kit::Badge.new("Peer feedback", variant: :info)
  end

  # @!endgroup
end
