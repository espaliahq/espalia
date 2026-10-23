# frozen_string_literal: true

# @label Badge
class Kit::BadgePreview < Lookbook::Preview
  Badge = Components::Kit::Badge

  # @param label text
  # @param variant select { choices: [subtle, solid, outline] }
  # @param tone select { choices: [neutral, brand, info, success, warning, danger] }
  # @param size select { choices: [sm, md] }
  # @param leading_icon select { choices: ["", plus, pencil, archive, discuss, chevron-down] }
  # @param trailing_icon select { choices: ["", plus, pencil, archive, discuss, chevron-down] }
  def playground(label: "Aligned", variant: :subtle, tone: :success, size: :sm, leading_icon: "", trailing_icon: "")
    render Badge.new(label, variant: variant.to_sym, tone: tone.to_sym, size: size.to_sym,
                            leading_icon: leading_icon.presence, trailing_icon: trailing_icon.presence)
  end

  # Every form × tone × size, on a card and on the page
  def matrix
    render_with_template(locals: { variants: Badge::VARIANTS.keys, tones: Badge::TONES.keys, sizes: Badge::SIZES.keys })
  end

  # @!group Parts

  def leading_icon
    render Badge.new("2 comments", tone: :info, leading_icon: "discuss")
  end

  def trailing_icon
    render Badge.new("Draft", variant: :outline, trailing_icon: "chevron-down")
  end

  def count
    render Badge.new("3", variant: :solid, tone: :danger)
  end

  def medium
    render Badge.new("At risk", tone: :warning, size: :md, leading_icon: "archive")
  end

  # @!endgroup

  # The job-named variants still in views map to a subtle tone until each view moves
  def legacy_variants
    render_with_template(locals: { variants: Badge::LEGACY_VARIANTS.keys })
  end
end
