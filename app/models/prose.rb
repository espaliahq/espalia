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
#   Prose.to_plain("See [the RFC](https://example.com)") # => "See the RFC (https://example.com)"
module Prose
  OPTIONS = {
    # escape: typed HTML shows as text. hardbreaks: a single newline stays a
    # line break, as it always has in these fields.
    render: { unsafe: false, escape: true, hardbreaks: true },
    extension: { autolink: true, strikethrough: true, tagfilter: true, table: false, header_ids: nil }
  }.freeze
  # Its own keyword, not part of OPTIONS: Commonmarker ignores a plugins key
  # there and loads its syntax highlighter on every call, 50x the render.
  PLUGINS = { syntax_highlighter: nil }.freeze

  ALLOWED_TAGS = %w[p br a strong em del code pre ul ol li blockquote].freeze
  BLOCK_TAGS = %w[p ul ol li blockquote pre].freeze
  LINK_SCHEMES = %w[http https mailto].freeze
  LINK_REL = "noopener noreferrer nofollow"

  # What a composer tells its author, beside the field.
  COMPOSER_HINT = "Markdown and links work"

  module_function

  # @param text [String, nil]
  # @return [String] sanitized HTML; empty for blank input
  def to_html(text)
    fragment(text).to_html
  end

  # The text a reader would see, without Markdown syntax — for excerpts,
  # previews and notifications. A link keeps its URL beside its text, so a
  # Slack excerpt can still be followed, and line breaks survive.
  #
  # @param text [String, nil]
  # @return [String]
  def to_plain(text)
    plain = +""
    write_plain(fragment(text), plain)
    plain.gsub(/[ \t]+/, " ").gsub(/ *\n */, "\n")
         .gsub(/^-\n+/, "- ")             # a loose list item's paragraph joins its dash
         .gsub(/\n+(?=- )/, "\n")         # list items sit on consecutive lines
         .gsub(/\n{3,}/, "\n\n").strip
  end

  # The sentence an MCP tool adds for each text field that renders through
  # Prose — named, because the same tool may take framework text that doesn't.
  #
  # @param fields [Array<String, Symbol>]
  # @return [String]
  def mcp_note(*fields)
    names = fields.map { |field| "`#{field}`" }.to_sentence
    "#{names} #{fields.one? ? "is" : "are"} Markdown: links, **bold**, _italic_, lists and `code` render, " \
      "a bare URL becomes a link, typed HTML shows as text and images render as links."
  end

  # Whether a URL may become a link.
  #
  # @param href [String, nil]
  # @return [Boolean]
  def linkable?(href)
    value = href.to_s.strip
    # Browsers drop tabs and newlines inside a URL, so "java\tscript:" would
    # run; refuse any control character rather than trust the parse.
    return false if value.match?(/[\x00-\x1F\x7F]/)

    LINK_SCHEMES.include?(URI.parse(value).scheme&.downcase)
  rescue URI::InvalidURIError
    false
  end

  # @return [Nokogiri::HTML5::DocumentFragment]
  def fragment(text)
    return Nokogiri::HTML5.fragment("") if text.blank?

    Sanitizer.call(Nokogiri::HTML5.fragment(Commonmarker.to_html(text.to_s, options: OPTIONS, plugins: PLUGINS)))
  end

  def write_plain(node, out)
    node.children.each do |child|
      if child.text?
        # Commonmarker's own newlines are formatting; <br> and blocks carry the breaks.
        out << (child.ancestors("pre").any? ? child.text : child.text.tr("\n", " "))
      elsif child.name == "br"
        out << "\n"
      elsif child.name == "a"
        out << link_text(child)
      else
        out << "\n" if BLOCK_TAGS.include?(child.name)
        out << "- " if child.name == "li"
        write_plain(child, out)
        out << "\n" if BLOCK_TAGS.include?(child.name)
      end
    end
  end

  def link_text(anchor)
    text = anchor.text
    href = anchor["href"].to_s
    shown = href.delete_prefix("mailto:")
    text == href || text == shown ? text : "#{text} (#{shown})"
  end

  private_class_method :fragment, :write_plain, :link_text

  # Reduces Commonmarker's output to {ALLOWED_TAGS}. Plain Nokogiri rather
  # than a Loofah scrubber: Loofah's traversal cost ~6ms on a short comment,
  # which a feed of excerpts multiplies.
  module Sanitizer
    DROP_WITH_CONTENT = %w[script style iframe object embed template noscript svg math].freeze

    module_function

    # @param fragment [Nokogiri::HTML5::DocumentFragment]
    # @return [Nokogiri::HTML5::DocumentFragment] the same fragment, cleaned
    def call(fragment)
      # Post-order, so a node's children are already clean when it is unwrapped.
      nodes = []
      fragment.children.each { |child| child.traverse { |node| nodes << node } }
      nodes.each { |node| scrub(node) }
      fragment
    end

    def scrub(node)
      return if node.text?
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

    def scrub_link(node)
      return unwrap(node) unless Prose.linkable?(node["href"])

      keep_only(node, %w[href])
      node["rel"] = LINK_REL
      node["target"] = "_blank"
    end

    def replace_image(node)
      src = node["src"]
      return node.replace(node.document.create_text_node(node["alt"].to_s)) unless Prose.linkable?(src)

      link = node.document.create_element("a", node["alt"].presence || src,
                                          href: src, rel: LINK_REL, target: "_blank")
      node.replace(link)
    end

    def flatten_heading(node)
      strong = node.document.create_element("strong")
      strong.children = node.children
      node.name = "p"
      keep_only(node, [])
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
