# frozen_string_literal: true

# Computes a grapheme-level diff between an original and a proposed string
# for inline rendering of a pending text-edit suggestion in the Framework
# Explorer grid.
#
# The returned segments can be rendered as a compact "track changes" view
# (added graphemes styled as proposed, removed graphemes struck through).
# When the diff has more than {MAX_CHANGE_RUNS} distinct change runs the
# interleaved view becomes visually noisy, so this class returns
# {:fallback} — callers render just the proposed text instead.
#
# @example
#   Frameworks::SuggestionDiff.call(original: "Focus", proposed: "Focussed")
#   # => [
#   #   { kind: :equal,   text: "Focus" },
#   #   { kind: :added,   text: "sed"   }
#   # ]
#
class Frameworks::SuggestionDiff
  # A change run = a contiguous segment with kind :added or :removed.
  # At four runs the interleaved view typically overwhelms the reader,
  # so we drop back to a proposed-only rendering.
  MAX_CHANGE_RUNS = 3

  # @param original [String]
  # @param proposed [String]
  # @return [Array<Hash>, Symbol] either an array of { kind:, text: } segments
  #   where kind is :equal, :added, or :removed, or the symbol :fallback.
  def self.call(original:, proposed:)
    new(original: original, proposed: proposed).call
  end

  def initialize(original:, proposed:)
    @original = original.to_s
    @proposed = proposed.to_s
  end

  # @return [Array<Hash>, Symbol]
  def call
    return equal_only if @original == @proposed

    segments = compute_segments
    return equal_only if changes_whitespace_only?(segments)
    return :fallback if change_run_count(segments) > MAX_CHANGE_RUNS

    segments
  end

  private

  def compute_segments
    raw = raw_ops

    # Collapse each contiguous run of non-equal ops into a single
    # removed-then-added pair. Without this step a multi-grapheme
    # replacement like "cat" -> "dog" would render as three alternating
    # remove/add segments (six change runs) instead of one remove run
    # followed by one add run.
    segments = []
    i = 0
    while i < raw.length
      kind, text = raw[i]
      if kind == :equal
        append(segments, :equal, text)
        i += 1
      else
        removes = +""
        adds = +""
        while i < raw.length && raw[i][0] != :equal
          sub_kind, sub_text = raw[i]
          (sub_kind == :removed ? removes : adds) << sub_text
          i += 1
        end
        append(segments, :removed, removes) unless removes.empty?
        append(segments, :added, adds) unless adds.empty?
      end
    end
    segments
  end

  def raw_ops
    ops = []
    Diff::LCS.sdiff(@original.grapheme_clusters, @proposed.grapheme_clusters).each do |change|
      case change.action
      when "="
        ops << [ :equal, change.new_element ]
      when "-"
        ops << [ :removed, change.old_element ]
      when "+"
        ops << [ :added, change.new_element ]
      when "!"
        ops << [ :removed, change.old_element ]
        ops << [ :added, change.new_element ]
      end
    end
    ops
  end

  def append(segments, kind, text)
    last = segments.last
    if last && last[:kind] == kind
      last[:text] += text
    else
      segments << { kind: kind, text: text.dup }
    end
  end

  # When every non-equal run is pure whitespace (e.g. trailing-space trims,
  # doubled-space collapses), the visible "change" is noise. Treat the
  # diff as a no-op and render the proposed text plainly.
  def changes_whitespace_only?(segments)
    changed = segments.reject { |seg| seg[:kind] == :equal }
    return false if changed.empty?

    changed.all? { |seg| seg[:text].match?(/\A\s*\z/) }
  end

  def change_run_count(segments)
    segments.count { |seg| seg[:kind] != :equal }
  end

  def equal_only
    [ { kind: :equal, text: @proposed } ]
  end
end
