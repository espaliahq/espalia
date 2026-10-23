# frozen_string_literal: true

# @label Tag
class Kit::TagPreview < Lookbook::Preview
  Tag = Components::Kit::Tag

  # @param label text
  # @param category select { choices: ["", 1, 2, 3, 4, 5, 6, 7, 8] }
  # @param key text "Hashed to a category when no category is chosen"
  # @param size select { choices: [xs, sm] }
  # @param leading_icon select { choices: ["", plus, pencil, archive, chevron-down] }
  # @param trailing_icon select { choices: ["", plus, pencil, archive, chevron-down] }
  def playground(label: "Delivery", category: "", key: "", size: :sm, leading_icon: "", trailing_icon: "")
    render Tag.new(label, category: category.presence&.to_i || key.presence, size: size.to_sym,
                          leading_icon: leading_icon.presence, trailing_icon: trailing_icon.presence)
  end

  # The eight categories in order, at both sizes, on a card and on the page
  def categories
    render_with_template(locals: { categories: Tag::CATEGORIES.keys, sizes: Tag::SIZES.keys })
  end

  # Capability categories keyed by name: each keeps its hue wherever it appears
  def hashed_keys
    render_with_template(locals: { names: %w[Delivery Craft Collaboration Leadership Ownership Communication Growth Impact] })
  end

  # No category: a neutral tag
  def neutral
    render_with_template(locals: { sizes: Tag::SIZES.keys })
  end

  # Leading and trailing icons scale with the size
  def with_icons
    render_with_template(locals: { sizes: Tag::SIZES.keys })
  end
end
