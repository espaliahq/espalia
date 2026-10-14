# frozen_string_literal: true

# The Markdown people write in feedback, comments and notes, made safe to show.
#
# Text is stored exactly as typed; this is the one place it becomes HTML
# (#482). Commonmarker escapes any HTML the author typed rather than dropping
# it, so nothing written disappears, and its output then passes an allowlist:
# no images (a remote image reports the reader's IP and a timestamp to
# whoever owns the URL — an image becomes a plain link instead), no headings
# (a line starting "# 3" is a sentence, not a title), and links only to
# http, https and mailto.
#
# @example
#   Prose.to_html("See [the RFC](https://example.com)")
#   # => "<p>See <a href=\"https://example.com\" rel=\"noopener noreferrer nofollow\" target=\"_blank\">the RFC</a></p>"
#   Prose.to_plain("See [the RFC](https://example.com)") # => "See the RFC"
module Prose
  OPTIONS = {
    # escape: typed HTML shows as text. hardbreaks: a single newline stays a
    # line break, as it always has in these fields.
    render: { unsafe: false, escape: true, hardbreaks: true },
    extension: { autolink: true, strikethrough: true, tagfilter: true, table: false, header_ids: nil },
    plugins: { syntax_highlighter: nil }
  }.freeze

  ALLOWED_TAGS = %w[p br a strong em del code pre ul ol li blockquote].freeze
  LINK_SCHEMES = %w[http https mailto].freeze
  LINK_REL = "noopener noreferrer nofollow"

  # What a composer tells its author, beside the field.
  COMPOSER_HINT = "Markdown and links work"

  # The same, for an MCP tool whose text field renders through {Prose}.
  MCP_NOTE = "The text is Markdown: links, **bold**, _italic_, lists and `code` render, " \
             "a bare URL becomes a link, typed HTML shows as text and images render as links."

  module_function

  # @param text [String, nil]
  # @return [String] sanitized HTML; empty for blank input
  def to_html(text)
    return "" if text.blank?

    fragment = Loofah.fragment(Commonmarker.to_html(text.to_s, options: OPTIONS))
    fragment.scrub!(Scrubber.new)
    fragment.to_s
  end

  # The text a reader would see, on one line — for excerpts, previews and
  # notifications, where Markdown syntax would show as punctuation.
  #
  # @param text [String, nil]
  # @return [String]
  def to_plain(text)
    return "" if text.blank?

    Loofah.fragment(to_html(text)).to_text(encode_special_chars: false).squish
  end

  # Whether a URL may become a link.
  #
  # @param href [String, nil]
  # @return [Boolean]
  def linkable?(href)
    LINK_SCHEMES.include?(URI.parse(href.to_s.strip).scheme&.downcase)
  rescue URI::InvalidURIError
    false
  end

  # Reduces Commonmarker's output to {ALLOWED_TAGS}. Walks bottom-up so a
  # node's children are already clean when the node itself is unwrapped.
  class Scrubber < Loofah::Scrubber
    DROP_WITH_CONTENT = %w[script style iframe object embed template noscript svg math].freeze

    def initialize
      super
      @direction = :bottom_up
    end

    # @param node [Nokogiri::XML::Node]
    def scrub(node)
      return CONTINUE if node.text?
      return node.remove unless node.element?

      case node.name
      when *DROP_WITH_CONTENT then node.remove
      when "img" then replace_image(node)
      when /\Ah[1-6]\z/ then flatten_heading(node)
      when "a" then scrub_link(node)
      when *ALLOWED_TAGS then keep_only(node, node.name == "ol" ? %w[start] : [])
      else unwrap(node)
      end
    end

    private

    def scrub_link(node)
      href = node["href"]
      return unwrap(node) unless Prose.linkable?(href)

      keep_only(node, %w[href])
      node["rel"] = LINK_REL
      node["target"] = "_blank"
    end

    def replace_image(node)
      src = node["src"]
      return node.replace(Nokogiri::XML::Text.new(node["alt"].to_s, node.document)) unless Prose.linkable?(src)

      link = Nokogiri::XML::Node.new("a", node.document)
      link["href"] = src
      link["rel"] = LINK_REL
      link["target"] = "_blank"
      link.content = node["alt"].presence || src
      node.replace(link)
    end

    def flatten_heading(node)
      strong = Nokogiri::XML::Node.new("strong", node.document)
      strong.children = node.children
      node.name = "p"
      node.attribute_nodes.each(&:remove)
      node.children = strong
    end

    def keep_only(node, attributes)
      node.attribute_nodes.each { |attr| attr.remove unless attributes.include?(attr.name) }
    end

    def unwrap(node)
      node.before(node.children)
      node.remove
    end
  end
end
