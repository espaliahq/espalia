# frozen_string_literal: true

# Phlex helper for highlighting free-text search matches in the explorer
# matrix. Wraps each query-token occurrence in a `<mark>`. Used by the text
# frames (capability / category / expectation) and the capability-description
# line — every surface the {Frameworks::MatrixDataBuilder} search matches
# against, so a match is always visibly marked where it occurs.
#
# Safe by construction: builds Phlex text nodes (`plain`) and `mark` elements,
# never raw/unescaped HTML, so a query string can't inject markup.
module Views::Frameworks::Explorer::Concerns::SearchHighlight
  # Amber to match the search banner / affordance. text-inherit-ish so the
  # mark sits on the surrounding type colour.
  HIGHLIGHT_CLASSES = "rounded-[2px] bg-amber-200 text-amber-950 " \
                      "dark:bg-amber-400/40 dark:text-amber-50"

  # Emits `text`, wrapping each (case-insensitive) query-token match in a
  # `<mark>`. No-ops to plain text when `query` is blank or nothing matches,
  # so callers can call it unconditionally.
  #
  # @param text [String, nil]
  # @param query [String, nil] raw query — tokenised here (whitespace-split)
  def render_highlighted(text, query)
    str = text.to_s
    return plain(str) if str.empty?

    ranges = highlight_ranges(str, query.to_s.downcase.split)
    return plain(str) if ranges.empty?

    cursor = 0
    ranges.each do |start_idx, end_idx|
      plain(str[cursor...start_idx]) if start_idx > cursor
      mark(class: HIGHLIGHT_CLASSES) { plain(str[start_idx...end_idx]) }
      cursor = end_idx
    end
    plain(str[cursor..]) if cursor < str.length
  end

  private

  # Finds every token occurrence and merges overlapping/adjacent spans so
  # the emitted marks never nest or double-cover a character.
  #
  # @return [Array<Array(Integer, Integer)>] sorted, non-overlapping [start, end)
  def highlight_ranges(text, tokens)
    return [] if tokens.empty?

    down = text.downcase
    ranges = []
    tokens.each do |token|
      next if token.empty?

      from = 0
      while (idx = down.index(token, from))
        ranges << [ idx, idx + token.length ]
        from = idx + token.length
      end
    end
    merge_ranges(ranges)
  end

  def merge_ranges(ranges)
    return [] if ranges.empty?

    sorted = ranges.sort_by(&:first)
    merged = [ sorted.first.dup ]
    sorted.drop(1).each do |start_idx, end_idx|
      last = merged.last
      if start_idx <= last[1]
        last[1] = end_idx if end_idx > last[1]
      else
        merged << [ start_idx, end_idx ]
      end
    end
    merged
  end
end
