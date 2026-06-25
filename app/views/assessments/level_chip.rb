# frozen_string_literal: true

# Single level chip in the horizontal assessment level strip.
#
# Carries the Turbo Stream target ID `cell-<stable_id>-<ordinal>` so
# rating controller responses can replace individual chips in-place.
#
# The chip fill is the rating language; small corner glyphs are the
# content language. The two never share a visual primitive:
#
# - **Fill** — solid colour keyed by the {FrequencyPalette} when a
#   single perspective applies; a diagonal **split** (the viewer's own
#   rating top-left, the other party's bottom-right) when two visible
#   perspectives disagree; a faint tint / grey when unrated. The seam *is* the
#   misalignment signal — a split chip reads as "contested" regardless
#   of the two colours, so it survives colour-blindness and the
#   colours-too-close trap. (Replaces the former amber divergence dot.)
# - **Glyphs** — a paperclip (evidence) and speech bubble (comment) in
#   the bottom-right corner, so situational awareness ("which levels
#   have backing") is visible before drilling in. (Replaces the former
#   slate/violet activity dots and the green rated-check, which read as
#   "aligned".)
#
class Views::Assessments::LevelChip < Views::Base
  # Fill for a below-level cell whose rating is the assumed-consistent
  # default. Clearly blue ("Consistently" is blue in the palette), but a
  # shade lighter than the solid blue-500 of an explicit "Consistently"
  # so an assumed value stays distinguishable from a rated one.
  ASSUMED_CONSISTENT_BG = "bg-blue-300 dark:bg-blue-700"

  # Sentinel marking a split slice whose value is the assumed-consistent
  # default (an unrated perspective on a below-level cell) rather than an
  # explicit frequency — so it paints {ASSUMED_CONSISTENT_BG}, not grey.
  ASSUMED = :assumed_consistent

  # @param cell_data [Hash, nil] from MatrixDataBuilder
  # @param capability_stable_id [String]
  # @param ordinal [Integer]
  # @param person_level [Integer]
  # @param level_code [String] compact label (e.g. "E7")
  # @param context [Symbol] :self, :manager, or :alignment
  # @param viewer_is_manager [Boolean] whether the viewer is the
  #   manager-side party (manager or active rating delegate). Determines
  #   which perspective takes the top-left slice of a split (see
  #   {#paint_viewer_pair}); only consulted in :alignment context.
  # @param focused [Boolean] whether this chip is the currently focused level
  def initialize(cell_data:, capability_stable_id:, ordinal:, person_level:,
                 level_code:, context: :self, viewer_is_manager: false, focused: false)
    @cell_data = cell_data
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @level_code = level_code
    @context = context
    @viewer_is_manager = viewer_is_manager
    @focused = focused
  end

  def view_template
    button(
      id: "cell-#{@capability_stable_id}-#{@ordinal}",
      type: "button",
      class: chip_classes,
      aria: { label: aria_label, pressed: @focused.to_s },
      data: {
        level_ordinal: @ordinal,
        action: "click->matrix#focusChip",
        capability_stable_id: @capability_stable_id
      }
    ) do
      split_overlay if split?
      level_code_label
      current_level_badge if at_person_level?
      activity_glyphs if has_activity?
    end
  end

  private

  def chip_classes
    # `appearance-none` strips UA <button> chrome (gradient on macOS,
    # focus outline on Windows). Don't add `bg-transparent` / `text-
    # inherit` here — they're same-specificity utilities that win the
    # cascade against the chip_bg colours we actually want to paint
    # (the class-string still resolves to e.g. `bg-blue-500` but
    # rgba(0,0,0,0) paints). Tailwind preflight already neutralises
    # the UA button background; the chip_bg utility paints on top.
    base = "appearance-none " \
           "relative flex flex-col items-center justify-center " \
           "h-12 flex-1 min-w-[60px] rounded-lg cursor-pointer " \
           "transition-all border-2 " \
           "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-1 "
    if @focused
      base + "#{chip_bg} #{chip_text} #{focus_border} shadow-sm"
    else
      base + "#{chip_bg} #{chip_text} #{idle_border} hover:shadow-sm"
    end
  end

  # Explicit text colour so the level code reads against the chip fill
  # regardless of the surrounding card's inherited colour. Without this
  # the inherited text colour washes out against the tinted chip in
  # dark mode (Hard-Won Lesson: the chip fill is the only signal the
  # eye gets — the code needs to stay legible on top of it). Split
  # chips override this with an opaque backing on the code itself.
  def chip_text
    freq = primary_frequency
    if freq.nil?
      @ordinal < @person_level ? "text-blue-900 dark:text-blue-100" : "text-gray-700 dark:text-gray-200"
    else
      config = Views::Assessments::FrequencyPalette.config_for(freq)
      config ? config[:chip_txt] : "text-gray-700 dark:text-gray-200"
    end
  end

  def focus_border
    "border-gray-900 dark:border-white"
  end

  # Unrated idle chips need a quiet but discernible edge so the strip
  # doesn't read as one flat band of colour. Rated chips already carry
  # a solid fill so a transparent border there reads as edge enough.
  def idle_border
    return "border-transparent" if rated? || split?

    "border-gray-200 dark:border-gray-700"
  end

  # Screen-reader label spelling out which capability + level the chip
  # rates, plus the current frequency value (or "unrated") and whether
  # the visible perspectives disagree.
  def aria_label
    level_note = @context == :self ? "your level" : "current level"
    base = at_person_level? ? "Focus #{@level_code} (#{level_note})" : "Focus #{@level_code}"
    parts = [ "#{base}, rated #{rated_description}" ]
    parts << split_note if split?
    parts << activity_title if has_activity?
    parts.join(", ")
  end

  # A split with both slices explicitly rated is a disagreement; a split
  # where one slice is the assumed-consistent default reads as the rated
  # perspective diverging from the assumed value; a split with one slice
  # nil is just one perspective rated so far.
  def split_note
    _state, top, bottom = fill_state
    return "the unrated perspective is assumed consistent" if top == ASSUMED || bottom == ASSUMED

    top && bottom ? "perspectives differ" : "only one perspective rated"
  end

  def rated_description
    freq = primary_frequency
    freq.present? ? humanise_frequency(freq) : "unrated"
  end

  def humanise_frequency(freq)
    Views::Assessments::FrequencyPalette.phrase_for(freq).downcase
  end

  # Base chip background:
  # - solid → palette colour for the resolved frequency
  # - split → the manager (bottom-right) colour; {#split_overlay} paints
  #   the self triangle on top
  # - unrated below person's level → mid blue (assumed-consistent,
  #   since the person operates at a higher level). Blue because
  #   "Consistently" is blue in the {FrequencyPalette}; this clearly-blue
  #   tint reads as "consistent" at a glance, while staying a shade
  #   lighter than the solid blue-500/400 of a cell actually rated
  #   consistent so the two remain distinguishable. The earlier
  #   blue-100/60 wash was so faint people didn't register it as a
  #   consistent rating at all.
  # - unrated at/above person's level → neutral grey
  def chip_bg
    case fill_state.first
    when :solid
      palette_bg(fill_state[1])
    when :split
      palette_bg(fill_state[2])
    else
      @ordinal < @person_level ? ASSUMED_CONSISTENT_BG : "bg-gray-100 dark:bg-gray-700"
    end
  end

  def palette_bg(frequency)
    return ASSUMED_CONSISTENT_BG if frequency == ASSUMED

    config = Views::Assessments::FrequencyPalette.config_for(frequency)
    config ? config[:chip_bg] : "bg-gray-100 dark:bg-gray-700"
  end

  # The top-left triangle, painted over the base (bottom-right) fill via a
  # clip-path. The "/" seam runs bottom-left → top-right; the **viewer's
  # own** perspective takes the top-left slice and the **other party** the
  # bottom-right, so each viewer always sees themselves in the top-left
  # (see {#compute_fill_state}).
  def split_overlay
    span(
      class: "absolute inset-0 rounded-md #{palette_bg(fill_state[1])}",
      style: "clip-path: polygon(0 0, 100% 0, 0 100%);",
      data: { split: "true" },
      aria: { hidden: "true" }
    ) { }
  end

  # Level code. When the chip is split the code sits across the seam, so
  # it gets an opaque backing to stay legible over whichever two colours
  # meet underneath; otherwise the chip's own text colour suffices.
  def level_code_label
    if split?
      span(class: "relative z-[1] px-1 rounded text-[11px] font-semibold " \
                  "bg-white/85 dark:bg-gray-900/85 text-gray-900 dark:text-gray-50") { @level_code }
    else
      span(class: "text-xs font-medium relative z-[1]") { @level_code }
    end
  end

  # The chip's fill state, derived once:
  #   [:unrated]
  #   [:solid, frequency]
  #   [:split, top_left_frequency, bottom_right_frequency]
  #
  # Corner position tracks **the viewer's own perspective**, not a fixed
  # self/manager assignment: the viewer's rating takes the top-left slice,
  # the other party's the bottom-right. So a viewer always sees their own
  # rating in the same corner, and the manager view and the manager's
  # alignment view read identically. (Tying position to context's "primary"
  # perspective instead swapped the corners between manager view — manager
  # primary, top-left — and alignment — self primary, top-left — which read
  # as the ratings jumping sides.)
  # - :manager   → viewer is the manager → manager top-left, self bottom-right.
  # - :alignment → a recorded aligned value resolves the cell to :solid
  #   (no split); while unresolved the two perspectives being reconciled
  #   show the viewer's own top-left (manager-side viewer → manager top-left;
  #   the assessee → self top-left).
  # A split is only produced in :manager / :alignment context, where the
  # viewer can see a second perspective. A split slice whose frequency is
  # nil (one side rated, the other not) paints grey.
  def fill_state
    @fill_state ||= compute_fill_state
  end

  def compute_fill_state
    return [ :unrated ] unless @cell_data

    case @context
    when :self
      freq = @cell_data[:current_frequency]
      freq.present? ? [ :solid, freq ] : [ :unrated ]
    when :manager
      paint_viewer_pair
    when :alignment
      aligned = @cell_data[:aligned_frequency]
      return [ :solid, aligned ] if aligned.present?

      paint_viewer_pair
    else
      [ :unrated ]
    end
  end

  # The viewer's own rating takes the top-left slice, the other party's the
  # bottom-right — so the split reads identically whoever is looking. The
  # manager-side party (the manager or an active rating delegate) is the
  # viewer when {#viewer_is_manager_side?}; otherwise the assessee.
  def paint_viewer_pair
    self_freq = @cell_data[:current_frequency]
    mgr_freq  = @cell_data[:manager_frequency]
    own, other = viewer_is_manager_side? ? [ mgr_freq, self_freq ] : [ self_freq, mgr_freq ]
    paint_pair(top_left: own, bottom_right: other)
  end

  # Whether the viewer is the manager-side party. In :manager context the
  # viewer is the manager by definition, so we treat it as manager-side even
  # if the flag wasn't threaded; :alignment relies on the explicit flag
  # (either party can be viewing). :self never reaches here (it never splits).
  def viewer_is_manager_side?
    @viewer_is_manager || @context == :manager
  end

  # Both absent → unrated. Otherwise resolve each slice — an unrated
  # perspective on a cell BELOW the person's level defaults to
  # assumed-consistent (the same default the solo chip and the scoring
  # use), but only when the counterpart WAS rated (a cell with neither
  # perspective rated stays the lighter solo "assumed" tint via the
  # :unrated branch, so it doesn't masquerade as a solid rated cell).
  #
  # Solid only when both slices are explicit AND equal — {ASSUMED} is a
  # symbol, so it never equals a frequency string. An explicitly-rated
  # "consistent" therefore still splits against an assumed-consistent
  # default, showing the two blue shades (solid blue-500 vs the lighter
  # assumed blue) in their perspective positions rather than collapsing to
  # one fill. A slice left nil (an unrated perspective at/above the
  # person's level, where there's no default) paints grey — so "I rated,
  # they haven't" reads as colour-vs-grey above the person's level.
  def paint_pair(top_left:, bottom_right:)
    return [ :unrated ] if top_left.nil? && bottom_right.nil?

    top    = top_left || assumed_default(counterpart: bottom_right)
    bottom = bottom_right || assumed_default(counterpart: top_left)

    return [ :solid, top ] if top == bottom

    [ :split, top, bottom ]
  end

  # The {ASSUMED} default for an unrated slice whose counterpart was rated,
  # on a below-level cell; otherwise nil (no default → paints grey).
  def assumed_default(counterpart:)
    return nil if counterpart.nil?

    @ordinal < @person_level ? ASSUMED : nil
  end

  def split?
    fill_state.first == :split
  end

  def primary_frequency
    return nil unless @cell_data

    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  def at_person_level?
    @ordinal == @person_level
  end

  def rated?
    primary_frequency.present?
  end

  # Marks the assessee's current level. Says "YOU" only in self context;
  # from the manager / alignment perspective the level belongs to the
  # report, so "YOU" would be misleading — use the neutral "CURRENT".
  def current_level_badge
    span(class: "absolute -bottom-0.5 left-1/2 -translate-x-1/2 " \
                "text-[9px] font-bold uppercase tracking-wider " \
                "bg-gray-800 dark:bg-white text-white dark:text-gray-900 " \
                "px-1.5 py-px rounded-sm") { current_level_label }
  end

  def current_level_label
    @context == :self ? "YOU" : "CURRENT"
  end

  # Evidence / comment indicators in the bottom-right corner. Glyphs —
  # paperclip (evidence), speech bubble (comment) — rather than coloured
  # dots: a shape says what it is without a colour legend, and it can't
  # be mistaken for the frequency-colour language used by the chip fill.
  # Both sit on one muted backing pill so they stay legible over any
  # fill while reading as ambient metadata, not a primary affordance.
  #
  # Corners in use: top-left/bottom-right (split fill), bottom-center
  # (YOU badge), bottom-right (these glyphs — clear of the centered YOU
  # badge).
  def activity_glyphs
    span(
      class: "absolute bottom-0.5 right-0.5 inline-flex items-center gap-0.5 " \
             "rounded-full bg-white/85 dark:bg-gray-900/85 px-0.5 " \
             "text-gray-600 dark:text-gray-300",
      title: activity_title,
      aria: { hidden: "true" }
    ) do
      evidence_glyph if evidence_count.positive?
      comment_glyph if comment_count.positive?
    end
  end

  def evidence_glyph
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "w-2.5 h-2.5",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2",
      data: { glyph: "evidence" }
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        d: "M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48"
      )
    end
  end

  def comment_glyph
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "w-2.5 h-2.5",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2",
      data: { glyph: "comment" }
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        d: "M21 11.5a8.38 8.38 0 01-.9 3.8 8.5 8.5 0 01-7.6 4.7 8.38 8.38 0 01-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 01-.9-3.8 8.5 8.5 0 014.7-7.6 8.38 8.38 0 013.8-.9h.5a8.48 8.48 0 018 8v.5z"
      )
    end
  end

  def has_activity?
    evidence_count.positive? || comment_count.positive?
  end

  def evidence_count
    @cell_data&.dig(:evidence_count).to_i
  end

  def comment_count
    @cell_data&.dig(:comment_count).to_i
  end

  def activity_title
    parts = []
    parts << "#{evidence_count} #{evidence_count == 1 ? 'evidence item' : 'evidence items'}" if evidence_count.positive?
    parts << "#{comment_count} #{comment_count == 1 ? 'comment' : 'comments'}" if comment_count.positive?
    parts.join(", ")
  end
end
