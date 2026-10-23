# frozen_string_literal: true

# @label Icons
class Kit::IconSpritePreview < Lookbook::Preview
  # Every glyph in the sprite, at the common size and enlarged.
  def gallery
    render Gallery.new(sizes: %w[w-4\ h-4 w-8\ h-8])
  end

  # Every glyph in each colour the app draws icons in.
  def colours
    render Gallery.new(sizes: %w[w-6\ h-6], colours: [ "text-muted", "text-brand", "text-danger" ])
  end

  class Gallery < Components::Base
    def initialize(sizes:, colours: [ nil ])
      @sizes = sizes
      @colours = colours
    end

    def view_template
      ul(class: "grid grid-cols-[repeat(auto-fill,minmax(8rem,1fr))] gap-4") do
        Components::Kit::IconSprite::NAMES.each { |name| tile(name) }
      end
    end

    private

    def tile(name)
      li(class: "flex flex-col items-center gap-2 rounded-lg border border-default bg-default p-4") do
        div(class: "flex items-end gap-3") do
          @colours.each do |colour|
            @sizes.each { |size| icon(name, class: [ size, colour ].compact.join(" ")) }
          end
        end
        code(class: "text-xs text-muted") { name }
      end
    end
  end
end
