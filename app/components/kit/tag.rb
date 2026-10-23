# frozen_string_literal: true

# A classification label: a level code, a role family, a capability category. Fully rounded, so
# it reads apart from a square badge; a category takes its hue from the categorical palette.
#
# @example A category, hashed from a stable key so it keeps its hue on every screen
#   render Components::Kit::Tag.new("Delivery", category: capability.stable_id)
#
# @example A fixed category, small, with an icon
#   render Components::Kit::Tag.new("E3", category: 1, size: :xs)
#
# @example Neutral
#   render Components::Kit::Tag.new("Archived")
class Components::Kit::Tag < Components::Base
  CATEGORY_COUNT = 8

  BASE = "inline-flex max-w-full shrink-0 items-center gap-1 rounded-full whitespace-nowrap leading-none"

  CATEGORIES = {
    1 => "bg-category-1 text-category-1",
    2 => "bg-category-2 text-category-2",
    3 => "bg-category-3 text-category-3",
    4 => "bg-category-4 text-category-4",
    5 => "bg-category-5 text-category-5",
    6 => "bg-category-6 text-category-6",
    7 => "bg-category-7 text-category-7",
    8 => "bg-category-8 text-category-8"
  }.freeze

  NEUTRAL = "bg-neutral-subtle text-muted"

  SIZES = {
    xs: "h-4 px-1.5 text-[10px] font-semibold",
    sm: "h-5 px-2 text-xs font-medium"
  }.freeze

  ICON_SIZES = {
    xs: "size-2.5",
    sm: "size-3"
  }.freeze

  # The category (1–8) for a key, the same for that key on every call and every server.
  # @param key [Integer, #to_s] 1–8 as given; anything else is hashed
  # @return [Integer]
  # @raise [ArgumentError] for an Integer outside 1–8
  def self.category_for(key)
    return Zlib.crc32(key.to_s) % CATEGORY_COUNT + 1 unless key.is_a?(Integer)
    raise ArgumentError, "category must be 1–#{CATEGORY_COUNT}, got #{key}" unless CATEGORIES.key?(key)

    key
  end

  # @param label [String] the tag text
  # @param category [Integer, #to_s, nil] 1–8, a key hashed to one, or nil for neutral
  # @param size [Symbol] :xs or :sm
  # @param leading_icon [String, Symbol, nil] a sprite icon before the label
  # @param trailing_icon [String, Symbol, nil] a sprite icon after the label
  # @param attrs [Hash] passed through to the span; `class:` is appended
  def initialize(label, category: nil, size: :sm, leading_icon: nil, trailing_icon: nil, **attrs)
    @label = label
    @colour = category.nil? ? NEUTRAL : CATEGORIES.fetch(self.class.category_for(category))
    @size = SIZES.fetch(size)
    @icon_size = ICON_SIZES.fetch(size)
    @leading_icon = leading_icon
    @trailing_icon = trailing_icon
    @attrs = attrs
  end

  def view_template
    span(**@attrs, class: [ BASE, @size, @colour, @attrs[:class] ].compact.join(" ")) do
      icon(@leading_icon, class: "#{@icon_size} shrink-0") if @leading_icon
      span(class: "truncate") { @label }
      icon(@trailing_icon, class: "#{@icon_size} shrink-0") if @trailing_icon
    end
  end
end
