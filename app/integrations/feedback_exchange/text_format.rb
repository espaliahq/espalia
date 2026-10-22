# frozen_string_literal: true

# Converts a peer's feedback text to the Markdown GrowthOS stores (protocol
# §4.1: `markdown` is canonical, a producer that stores anything else says so
# and the consumer converts).
#
# - `markdown` passes through untouched.
# - `slack` is Slack's mrkdwn: `*b*`, `_i_`, `~s~`, `•`/`◦` bullets nested by
#   four spaces, `<url|text>` links and `<@U…>` mentions.
# - `plain` is text with no markup, so the characters Markdown would read as
#   formatting are escaped.
#
# Both convert `label (url)`, the shape {Prose.to_plain} gives a link, back
# into `[label](url)`. The label runs back to the start of the line or the
# nearest `. ! ? : ; ,`, which is where to_plain's own labels end.
#
# A mention resolves to the person's name through `TenantUser.slack_user_id`
# in the current tenant, else to the name Slack carried (`<@U…|name>`), else
# `@someone`.
#
# @example
#   FeedbackExchange::TextFormat.to_markdown("*Great* work on <https://x.io|the RFC>", format: "slack")
#   # => "**Great** work on [the RFC](https://x.io)"
module FeedbackExchange::TextFormat
  FORMATS = %w[markdown slack plain].freeze
  UNKNOWN_MENTION = "@someone"

  # Placeholder delimiters for spans that must pass through untouched. Neither
  # is whitespace or a formatting character, so the inline rules never see them;
  # the character is stripped from the input so a peer's text cannot forge one.
  HOLD = "\u0001"
  HELD = /\u0001(\d+)\u0001/

  FENCE = /```(.*?)```/m
  INLINE_CODE = /`[^`\n]+`/
  SLACK_TOKEN = /<([^<>\n]+)>/
  BARE_URL = %r{https?://[^\s<>()]+[^\s<>().,;:!?'"]}
  LABELLED_URL = /(?<label>[^.!?:;,\n\u0001]*[^\s.!?:;,\u0001]) \((?<url>https?:\/\/[^\s()]+)\)/
  # Slack's emphasis: the marker hugs non-space text and is not inside a word.
  EMPHASIS = /(?<![\p{Alnum}\\])([*_~])(?=\S)([^\n]*?\S)\1(?![\p{Alnum}])/
  EMPHASIS_MARKDOWN = { "*" => "**", "_" => "*", "~" => "~~" }.freeze
  BULLET = /\A(?<indent>\s*)[•◦▪▫‣] +/
  QUOTE = /\A(?:&gt;|>) ?/
  ENTITIES = { "&lt;" => "<", "&gt;" => ">", "&amp;" => "&" }.freeze
  PLAIN_ESCAPES = /([\\*_`~\[\]])/

  module_function

  # @param text [String, nil]
  # @param format [String] one of {FORMATS}; anything else is treated as plain
  # @return [String]
  def to_markdown(text, format:)
    text = text.to_s
    case format.to_s
    when "markdown" then text
    when "slack" then new_run.slack(text.delete(HOLD))
    else new_run.plain(text.delete(HOLD))
    end
  end

  # One conversion, holding the spans it set aside.
  #
  # @api private
  def new_run
    Run.new
  end

  # @api private
  class Run
    def initialize
      @held = []
    end

    # @param text [String]
    # @return [String]
    def slack(text)
      out = text.split(FENCE, -1).each_with_index.map do |part, index|
        index.odd? ? fenced(part) : join_lines(part) { |line| slack_line(line) }
      end
      finish(out.join)
    end

    # @param text [String]
    # @return [String]
    def plain(text)
      finish(join_lines(text) { |line| plain_line(line) })
    end

    private

    # Slack quotes and bullets end with their line; Markdown would carry the
    # next line into them (a lazy continuation), so a blank line closes them.
    def join_lines(text)
      previous = nil
      text.lines(chomp: true).each_with_object([]) do |line, out|
        converted = yield(line)
        kind = block_kind(converted)
        out << "" if previous && previous != :text && kind != previous && converted.present?
        out << converted
        previous = converted.present? ? kind : nil
      end.join("\n")
    end

    def block_kind(line)
      case line
      when /\A\s*(?:- |\d+\. )/ then :list
      when /\A> / then :quote
      else :text
      end
    end

    def finish(text)
      restore(text).gsub(/\A\n+|\n+\z/, "")
    end

    def fenced(code)
      hold("\n```\n#{code.delete_prefix("\n").delete_suffix("\n")}\n```\n")
    end

    def slack_line(line)
      prefix, body = line_prefix(line)
      body = body.gsub(INLINE_CODE) { |code| hold(code) }
      body = body.gsub(SLACK_TOKEN) { hold(slack_token(Regexp.last_match(1))) }
      body = decode(body)
      body = hold_links(body)
      prefix + emphasis(body)
    end

    def plain_line(line)
      prefix, body = line_prefix(line)
      body = hold_links(body)
      prefix + body.gsub(PLAIN_ESCAPES) { "\\#{Regexp.last_match(1)}" }
    end

    # Bullets become Markdown list items at the same indent; quotes, ordered
    # items and everything else keep their marker.
    def line_prefix(line)
      if (match = BULLET.match(line))
        [ "#{match[:indent]}- ", match.post_match ]
      elsif (match = QUOTE.match(line))
        [ "> ", match.post_match ]
      else
        [ "", line ]
      end
    end

    def emphasis(text)
      text.gsub(EMPHASIS) do
        marker = EMPHASIS_MARKDOWN.fetch(Regexp.last_match(1))
        "#{marker}#{emphasis(Regexp.last_match(2))}#{marker}"
      end
    end

    def hold_links(text)
      text = text.gsub(LABELLED_URL) do
        label, url = Regexp.last_match.values_at(:label, :url)
        "#{label[/\A\s*/]}#{hold("[#{label.strip}](#{url})")}"
      end
      text.gsub(BARE_URL) { |url| hold(url) }
    end

    # Slack's angle-bracket tokens: links, mentions, channels and specials.
    def slack_token(token)
      target, label = token.split("|", 2)
      case target
      when /\A@/ then mention(target.delete_prefix("@"), label)
      when /\A#/ then "##{label.presence || 'channel'}"
      when /\A!subteam\^/ then label.presence || "@team"
      when /\A!date\^/ then label.to_s
      when /\A!(here|channel|everyone)/ then "@#{Regexp.last_match(1)}"
      when %r{\A(https?://|mailto:)} then link(target, label)
      else decode(token)
      end
    end

    def link(url, label)
      label.present? ? "[#{decode(label)}](#{url})" : "<#{url}>"
    end

    def mention(slack_user_id, label)
      name = TenantUser.where(slack_user_id: slack_user_id).joins(:person).pick("people.name")
      name.presence || (label.present? ? "@#{label.delete_prefix('@')}" : UNKNOWN_MENTION)
    end

    def decode(text)
      text.gsub(/&(lt|gt|amp);/) { |entity| ENTITIES.fetch(entity) }
    end

    def hold(text)
      @held << text
      "#{HOLD}#{@held.size - 1}#{HOLD}"
    end

    # Held spans can nest (a link inside a fence), so restore until none remain.
    def restore(text)
      text = text.gsub(HELD) { @held.fetch(Regexp.last_match(1).to_i) } while text.match?(HELD)
      text
    end
  end
end
