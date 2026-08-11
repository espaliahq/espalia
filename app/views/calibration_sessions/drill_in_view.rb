# frozen_string_literal: true

# The capability drill-in — expectation text per level above a
# rater × level dot grid, with a person card when a dot is opened.
#
# The room sees who it is discussing: a dot carries the ratee's INITIALS
# and their full name (tooltip + accessible name), and wall items show the
# author and the text. There is no anonymisation layer — see
# docs/architecture/calibration-sessions.md, "Naming".
# Three signals on a dot, three primitives that never collide: colour =
# frequency (the shared palette), fill = evidence backing (solid backed /
# outlined unbacked), dashed edge = carried forward from the previous cycle
# and unconfirmed.
class Views::CalibrationSessions::DrillInView < Views::Base
  include Views::Assessments::FrequencyPalette
  include Views::Evidence::Valence
  include Views::CalibrationSessions::Glossary
  include Views::CalibrationSessions::RaterColours
  include Views::CalibrationSessions::ComparisonDrawerChrome
  include Views::CalibrationSessions::PeopleNames

  UNRATED_DOT = "border-2 border-gray-300 dark:border-gray-600"

  # The ⓘ panel previews this many examples (across the level's calibrated
  # roles) — a reference glance, not a reading surface. The full list lives
  # on the person cards, where comparing people is the point.
  EXAMPLE_PREVIEW_LIMIT = 3

  RELATION_LABELS = { "self" => "Self", "manager" => "Manager", "peer" => "Peer feedback" }.freeze

  MAX_PINS = Views::CalibrationSessions::ComparisonDrawerChrome::MAX_PINS

  # @param session [CalibrationSession]
  # @param stats [Hash] DrillInStats result
  # @param people [Hash{String => Person}] rater people by id
  # @param person_card [Hash, nil] `{ dot:, ordinal:, rater_id:, evidence: }`
  # @param view [String, nil] bottom-pane view — "wall" / nil
  # @param wall [Hash, nil] EvidenceWall result when view == "wall"
  # @param wall_filters [Hash] `{ level:, valence:, rater_id: }` echoes
  # @param pin_ids [Array<String>] pinned person_ids (URL-carried)
  # @param pinned_cards [Hash{String => Hash}] person_id => PersonCard data
  # @param can_flag [Boolean] whether the viewer can ⚑ flag an expectation
  #   as unclear (facilitator/admin AND the session is live)
  def initialize(session:, stats:, people:, person_card:, can_flag: false,
                 person_focus_ordinal: nil, person_action: nil,
                 request_candidates: nil,
                 view: nil, wall: nil, wall_filters: {}, pin_ids: [], pinned_cards: {},
                 session_log: nil, can_note: false,
                 user: nil, current_tenant: nil, tenants: [])
    @session = session
    @stats = stats
    @people = people
    @person_card = person_card
    @person_focus_ordinal = person_focus_ordinal
    @person_action = person_action
    @can_flag = can_flag
    @request_candidates = request_candidates
    @session_log = session_log
    @can_note = can_note
    @view = view
    @wall = wall
    @wall_filters = wall_filters
    @pin_ids = pin_ids
    @pinned_cards = pinned_cards
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(
        # data-drawer-host: the comparison-drawer controller pads this by
        # the drawer's measured height, so page-end content clears the fixed
        # shelf — applied client-side because the drawer opens/closes via
        # frame swaps this wrapper (outside the frame) never re-renders for.
        # overflow-anchor: pane swaps insert/remove the wall mid-page and
        # Chrome's scroll anchoring turns that into a scroll jump (the
        # assessment scroll-root's lesson) — anchoring off, swaps hold still.
        class: "w-full px-4 sm:px-6 py-8 flex gap-6 items-start [overflow-anchor:none]",
        data: {
          drawer_host: "true",
          controller: "calibration-pane#{' activity-pane' if @session_log}",
          activity_pane_cookie_value: Views::CalibrationSessions::LogPane::DRILL_IN_COOKIE,
          # One delegated handler for every in-page pane link (dots, tabs,
          # pins, unpin, close) — they all differ from the current URL only
          # by query string, which is exactly how the controller spots them.
          action: "click->calibration-pane#navigate"
        }
      ) do
        div(class: "min-w-0 flex-1") do
          header_row
          grid_card
          bottom_pane
        end
        if @session_log
          render Views::CalibrationSessions::LogPane.new(
            session: @session, log: @session_log, people: @people, can_note: @can_note,
            note_fields: note_fields
          )
        end
      end
    end
  end

  private

  # Only must-have context is sticky: the capability's name (the grid's
  # rater/level heading is sticky inside its own scroll container). The
  # back link and log toggle scroll away with the flow — they're chrome,
  # not context.
  def header_row
    div(class: "flex flex-wrap items-center gap-3") do
      # The drawer follows the room home: whoever is open and pinned here
      # is open and pinned on the session page too.
      a(href: calibration_session_path(
          @session, { person: opened_person_id, pins: @pin_ids.presence }.compact
        ),
        class: "flex-1 min-w-0 text-sm text-gray-600 dark:text-gray-300 hover:underline") { "← #{@session.name}" }
      if @session_log
        render Views::CalibrationSessions::LogPaneToggle.new(
          entry_count: @session_log[:entries].size
        )
      end
    end
    div(class: "sticky top-0 z-30 -mx-4 sm:-mx-6 bg-gray-50 dark:bg-gray-900 px-4 sm:px-6 py-1.5") do
      div(class: "flex items-baseline gap-x-3 min-w-0") do
        if @stats[:capability][:category_name]
          span(class: "shrink-0 text-xs font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300") do
            @stats[:capability][:category_name]
          end
        end
        h1(class: "text-xl font-bold text-gray-900 dark:text-white truncate") { @stats[:capability][:name] }
      end
    end
  end

  # One level's reference material — the column header's ⓘ menu: the
  # canonical expectation, the role illustrations (each flaggable), and
  # the cell's ⚑ flag affordance. What the "What good looks like" card
  # used to show, now anchored to the column it describes.
  def level_header_menu(ordinal)
    render Components::Kit::Dropdown.new(strategy: :fixed, align: :left) do |dropdown|
      dropdown.trigger(label: "L#{ordinal} — expectation, examples, and flags") do
        # 44px tap target (the visual glyph stays small) — this is the only
        # route to the level's reference material. A DRAWN info glyph, not
        # the ⓘ character: headless/minimal font stacks render that as tofu.
        span(class: "inline-flex h-11 w-11 items-center justify-center rounded-md " \
                    "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700") do
          span(class: "inline-flex h-4 w-4 items-center justify-center rounded-full border " \
                      "border-current text-[10px] font-serif italic leading-none",
               aria: { hidden: "true" }) { "i" }
        end
      end
      dropdown.menu(width: "w-96", role: "dialog",
                    label: "L#{ordinal} — what good looks like") do
        div(class: "px-3 py-2 text-left") do
          p(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
            "L#{ordinal} — what good looks like"
          end
          p(class: "mt-1 text-sm text-gray-900 dark:text-white whitespace-normal") do
            @stats[:expectations][ordinal] || "No expectation defined at this level."
          end
          example_groups(ordinal, limit: EXAMPLE_PREVIEW_LIMIT)
          flag_affordance(ordinal)
        end
      end
    end
  end

  # The role illustrations under a level's canonical expectation, grouped
  # per role (only roles the calibration population holds at this level —
  # DrillInStats filters at the source). Each example is itself flaggable —
  # "this example is what misleads raters" is narrower and more actionable
  # than flagging the whole cell. `limit:` caps the total across groups
  # (the ⓘ preview); the person cards render the full list.
  def example_groups(ordinal, limit: nil)
    groups = @stats[:illustrations]&.dig(ordinal)
    return if groups.blank?

    total = groups.sum { |group| group[:items].size }
    remaining = limit
    div(class: "mt-2 space-y-1.5") do
      groups.each do |group|
        break if remaining&.zero?

        items = remaining ? group[:items].first(remaining) : group[:items]
        remaining -= items.size if remaining
        next if items.empty?

        div do
          span(class: "text-[11px] font-medium uppercase tracking-wide " \
                      "text-gray-600 dark:text-gray-300") { group[:role_name] }
          ul(class: "mt-0.5 space-y-1") do
            items.each { |item| example_row(item) }
          end
        end
      end
      if limit && total > limit
        p(class: "text-[11px] text-gray-600 dark:text-gray-300") do
          "+ #{total - limit} more — open a person's card to read them all"
        end
      end
    end
  end

  def example_row(item)
    li(class: "text-xs text-gray-700 dark:text-gray-200") do
      div(class: "flex gap-2") do
        span(class: "text-gray-400", aria: { hidden: "true" }) { "•" }
        div(class: "min-w-0 flex-1") do
          plain item[:text]
          example_flag(item)
        end
      end
    end
  end

  # Per-example ⚑ — an open illustration clarification (any session) shows
  # as a marker; otherwise a live session's facilitator can raise one.
  def example_flag(item)
    if @stats[:flagged_illustration_ids].include?(item[:id])
      div(class: "mt-0.5 text-[11px] font-medium text-amber-700 dark:text-amber-300") do
        "⚑ Example flagged — clarification open on the framework"
      end
    elsif @can_flag
      details(class: "mt-0.5") do
        summary(
          class: "inline-flex min-h-11 cursor-pointer items-center text-[11px] font-medium " \
                 "text-gray-600 dark:text-gray-300 hover:text-amber-700 dark:hover:text-amber-300",
          # The example text disambiguates — a level can hold several
          # identical "flag example" affordances (menu AND open cards).
          aria: { label: "Flag example as unclear — #{item[:text].to_s.truncate(60)}" }
        ) { "⚑ Flag example as unclear" }
        form(
          action: calibration_session_illustration_flags_path(@session),
          method: "post",
          class: "mt-1.5 max-w-lg space-y-2",
          data: { action: "submit->calibration-pane#stampState", turbo_frame: "_top" }
        ) do
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          input(type: "hidden", name: "illustration_id", value: item[:id])
          # The return path rebuilds THIS drill-in URL from it.
          input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
          state_passthrough_fields
          textarea(
            name: "reason", rows: "2",
            class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                   "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                   "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
            placeholder: "What misleads about this example (optional)",
            aria: { label: "Why this example is unclear — #{item[:text].to_s.truncate(60)}" }
          )
          button(
            type: "submit",
            class: "inline-flex items-center rounded-md bg-amber-600 px-3 py-2 text-xs " \
                   "font-semibold text-white hover:bg-amber-700 transition-colors"
          ) { "Flag example" }
        end
      end
    end
  end

  # Per-level ⚑ outcome: an already-open clarification (from ANY session —
  # overlapping sessions see each other's flags) renders as a marker; a live
  # session's facilitator gets the flag disclosure with an optional reason.
  # One flag per cell per session — the marker replaces the affordance.
  def flag_affordance(ordinal)
    open_count = @stats[:clarifications][ordinal].to_i
    if open_count.positive?
      div(class: "mt-1 text-xs font-medium text-amber-700 dark:text-amber-300") do
        plain "⚑ Flagged — #{open_count} open #{'clarification'.pluralize(open_count)} on the framework"
      end
    elsif @can_flag
      flag_form(ordinal)
    end
  end

  def flag_form(ordinal)
    details(class: "mt-1") do
      summary(
        class: "inline-flex min-h-11 cursor-pointer items-center text-xs font-medium " \
               "text-gray-600 dark:text-gray-300 hover:text-amber-700 dark:hover:text-amber-300"
      ) { "⚑ Flag expectation as unclear" }
      expectation_flag_form(ordinal)
    end
  end

  def expectation_flag_form(ordinal, field_id: "flag-reason-#{ordinal}")
    form(
        action: calibration_session_expectation_flags_path(@session),
        method: "post",
        class: "mt-2 max-w-lg space-y-2",
        # stampState refreshes the carried state from the live URL at
        # submit time; _top because the kebab renders this INSIDE the pane
        # frame — a frame-scoped submit would swallow the flash (success
        # AND refusal) exactly like the revisit form's comment warns.
        data: { action: "submit->calibration-pane#stampState", turbo_frame: "_top" }
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
        input(type: "hidden", name: "level_ordinal", value: ordinal)
        state_passthrough_fields
        textarea(
          id: field_id, name: "reason", rows: "2",
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          placeholder: "What is the room reading differently? (optional)",
          aria: { label: "What is unclear about this expectation" }
        )
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-amber-600 px-3 py-2 text-sm " \
                 "font-semibold text-white hover:bg-amber-700 transition-colors"
        ) { "Raise clarification" }
      end
  end

  def grid_card
    div(class: "mt-6") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex flex-wrap items-baseline justify-between gap-2") do
            h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
              "At-level ratings by rater"
            end
            div(class: "flex flex-wrap items-center gap-x-1 text-xs text-gray-600 dark:text-gray-300") do
              defined_term(:backing, align: :right)
              plain "· click a dot to discuss · pin up to #{MAX_PINS} to compare"
            end
          end

          # The grid scrolls INSIDE its card (capped height) so the level
          # headers stay pinned while the room scans a big org's raters.
          div(class: "mt-3 max-h-[60vh] overflow-auto") do
            table(class: "w-full text-sm") do
              thead do
                tr(class: "text-left text-xs text-gray-600 dark:text-gray-300") do
                  th(class: "sticky left-0 top-0 z-[3] bg-white dark:bg-gray-800 py-1.5 pr-3 font-medium") do
                    "Rater"
                  end
                  @stats[:ordinals].each do |ordinal|
                    # has-[…]:z-30 — sibling sticky headers share a stacking
                    # context, so a later column would paint THROUGH this
                    # column's open ⓘ menu unless the host th out-ranks its
                    # siblings while the menu is open.
                    th(class: "sticky top-0 z-[2] has-[[aria-expanded=true]]:z-40 " \
                              "bg-white dark:bg-gray-800 py-1.5 pr-3 font-medium",
                       data: { level_menu: ordinal }) do
                      div(class: "flex items-center gap-1") do
                        span { "L#{ordinal}" }
                        if @stats[:clarifications][ordinal].to_i.positive?
                          # Scannable without opening the menu — "which
                          # cells are already contested" was a one-glance
                          # read on the old expectations card.
                          span(class: "text-amber-700 dark:text-amber-300 font-semibold",
                               title: "#{@stats[:clarifications][ordinal]} open clarification(s) on this level's expectation") do
                            "⚑#{@stats[:clarifications][ordinal]}"
                          end
                        end
                        level_header_menu(ordinal)
                      end
                    end
                  end
                end
              end
              tbody do
                rated_rows.each { |row| grid_row(row) }
                unrated_raters_row
              end
            end
          end

          frequency_legend
        end
      end
    end
  end

  # Rows with at least one rated dot on THIS capability. A rater who hasn't
  # touched it yet renders as one muted sentence instead of a full row of
  # grey dots — a row of nothing reads as data on a projector, and the room
  # only needs to know who is missing. Their people are named in it AS
  # LINKS to their person cards: the unrated cell is precisely the "what
  # did you see?" moment, and the card is where the evidence and the
  # revisit ask live, so collapsing the row must never sever that path.
  # The "other raters" reference row is exempt — context, not a
  # participant being calibrated.
  def rated_rows
    @rated_rows ||= @stats[:rows].select do |row|
      row[:rater_id].nil? || row_has_rating?(row)
    end
  end

  def row_has_rating?(row)
    row[:people].values.flatten.any? { |dot| dot[:frequency] }
  end

  def unrated_raters_row
    missing = @stats[:rows].reject { |row| rated_rows.include?(row) }
    return if missing.empty?

    tr(class: "border-t border-gray-100 dark:border-gray-800") do
      td(class: "py-2.5 text-sm italic text-gray-600 dark:text-gray-300",
         colspan: @stats[:ordinals].size + 1) do
        missing.each_with_index do |row, index|
          plain ", " if index.positive?
          plain "#{rater_label(row)} hasn't rated this capability yet"
          people = row[:people].values.flatten
          next if people.empty?

          plain " ("
          people.each_with_index do |dot, person_index|
            plain ", " if person_index.positive?
            unrated_person_link(dot)
          end
          plain ")"
        end
        plain "."
      end
    end
  end

  # Same destination and pane behaviour as a dot — an inline link within
  # the sentence (the in-sentence exception to the 44px target rule).
  def unrated_person_link(dot)
    a(
      href: drill_in_path(view: nil, person: dot[:person_id], pins: [], filters: {}),
      class: "underline underline-offset-2 decoration-gray-400 dark:decoration-gray-500 " \
             "hover:decoration-gray-900 dark:hover:decoration-white",
      aria: { label: "#{dot[:name]} — unrated. Open to discuss." },
      data: { pane_keep_state: "true", person_id: dot[:person_id] }
    ) { dot[:name] }
  end

  def grid_row(row)
    tr(class: "border-t border-gray-100 dark:border-gray-800 #{'opacity-60' unless row[:in_session]}") do
      # Sticky-left like the explorer's matrix: the grid scrolls sideways on
      # a narrow viewport, and a scrolled-away rater name makes the dots
      # unattributable.
      td(class: "sticky left-0 z-[2] bg-white dark:bg-gray-800 py-2 pr-3 whitespace-nowrap") do
        span(class: "font-medium text-gray-900 dark:text-white") { rater_label(row) }
        unless row[:in_session]
          span(class: "ml-2 text-xs text-gray-600 dark:text-gray-300") { "(not in session)" }
        end
      end
      @stats[:ordinals].each do |ordinal|
        td(class: "py-2 pr-3") do
          div(class: "flex flex-wrap items-center") do
            (row[:people][ordinal] || []).each { |dot| render_dot(dot, ordinal) }
          end
        end
      end
    end
  end

  # The dot carries the member's INITIALS — a grid of unlabelled dots can't
  # be discussed ("which one is that?"), and the divergence board already
  # initials its rater dots. The full name rides the tooltip and the
  # accessible name.
  def render_dot(dot, ordinal)
    base = dot_description(dot, ordinal)
    pinned = @pin_ids.include?(dot[:person_id])
    base += " Pinned to the comparison." if pinned
    a(
      # Opening a dot returns to the person-card view but keeps the pins —
      # the room browses dots mid-comparison without losing the tray. The
      # grid sits OUTSIDE the pane frame, so this href freezes at whatever
      # the pins and filters were on page load; `pane_keep_state` tells the
      # pane controller to merge the live values in at click time.
      href: drill_in_path(view: nil, person: dot[:person_id], pins: [],
                          filters: {}),
      class: "inline-flex h-11 w-11 items-center justify-center",
      title: dot[:name],
      # Initials are the compact label; the accessible name carries the
      # person, since "BA" tells a screen-reader user nothing.
      aria: { label: "#{dot[:name]} — #{base}. Open to discuss." },
      data: { pane_keep_state: "true", person_id: dot[:person_id] }
    ) do
      span(class: "relative inline-flex") do
        span(
          class: "inline-flex h-7 w-7 items-center justify-center rounded-full " \
                 "text-[10px] font-semibold #{dot_classes(dot)}"
        ) { initials(dot[:name]) }
        pin_badge if pinned
      end
    end
  end

  # The violet corner disc marking a person held in the comparison drawer —
  # the main pane's "already pinned" affordance (rendered on the grid dots
  # here and the cohort dots on the session page). Decorative; the state
  # rides the accessible name.
  def pin_badge
    span(
      class: "absolute -top-1 -right-1 h-3 w-3 rounded-full bg-violet-600 " \
             "border border-white dark:border-gray-800",
      aria: { hidden: "true" }
    )
  end

  # Two letters, uppercased — the divergence board's convention.
  # Backed = solid fill, unbacked = outline (the backing signal is shape,
  # never colour). The initials sit on both, so each branch also picks a
  # text colour that clears AA against its own background.
  #
  # Solid dots use near-black rather than the palette's per-hue `chip_txt`:
  # at 10px these are small text needing 4.5:1, and hue-950 on hue-500 only
  # reaches ~4.0:1 on blue and ~4.3:1 on red. Near-black clears all four
  # fills in both modes.
  # Three independent signals, three primitives that never collide:
  # hue = frequency, fill = evidence backing (solid / outlined), and a
  # DASHED edge = carried forward from the previous cycle, unconfirmed —
  # the same "dashed means carried" vocabulary the assessment chips and
  # pills use (see FrequencyPalette). A carried backed dot also drops to the
  # lighter `chip_carried` tint, mirroring lighter = inherited.
  def dot_classes(dot)
    return "#{UNRATED_DOT} text-gray-600 dark:text-gray-300" unless dot[:frequency]

    config = CONFIG.fetch(dot[:frequency])
    if dot[:backed] && dot[:carried]
      "#{config[:chip_carried]} border-2 #{config[:chip_carried_border]} text-gray-950"
    elsif dot[:backed]
      "#{config[:chip_bg]} text-gray-950"
    else
      # Outline from the shared palette so an unbacked dot's hue can never
      # drift from the chips/pills for the same frequency.
      "border-2 #{config[:border]} #{'border-dashed' if dot[:carried]} " \
        "text-gray-900 dark:text-white"
    end
  end

  # Carried state must be conveyed non-visually too — the dashed edge is
  # decoration-only (FrequencyPalette's rule).
  def dot_description(dot, ordinal)
    rating = dot[:frequency] ? CONFIG.fetch(dot[:frequency])[:phrase] : "unrated"
    backing = dot[:backed] ? "evidence attached" : "no evidence"
    parts = [ "L#{ordinal}", rating, backing ]
    parts << "carried forward from the previous cycle" if dot[:carried]
    parts.join(" · ")
  end

  def frequency_legend
    div(class: "mt-4 flex flex-wrap gap-x-4 gap-y-1") do
      CONFIG.each do |_freq, config|
        div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
          span(class: "inline-block h-3 w-3 rounded-full #{config[:chip_bg]}", aria: { hidden: "true" })
          plain config[:phrase]
        end
      end
      div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
        span(class: "inline-block h-3 w-3 rounded-full #{UNRATED_DOT}", aria: { hidden: "true" })
        plain "Unrated"
      end
      div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
        span(class: "inline-block h-3 w-3 rounded-full border-2 border-dashed " \
                    "border-gray-500 dark:border-gray-400", aria: { hidden: "true" })
        plain "Carried from last cycle"
      end
    end
  end

  # ── Bottom pane: the evidence wall toggle + the comparison drawer ──

  # The pane lives in a Turbo Frame so switching panes, opening a dot, or
  # pinning replaces only this region — a full-page navigation would scroll
  # the room back to the top, hiding the very thing they just clicked.
  # `calibration_pane_controller` drives the frame's src and keeps the
  # browser URL in step (the matrix-frame pattern from the explorer and the
  # assessment views).
  def bottom_pane
    turbo_frame_tag("calibration-bottom-pane",
                    class: "block",
                    data: { calibration_pane_target: "frame" }) do
      wall_toggle
      wall_section if @view == "wall"
      comparison_drawer
    end
  end

  # Every pane link preserves the other axes (opened person, pins, filters)
  # so switching views never loses the room's working state.
  #
  # These look like tabs but ARE links that navigate the page, so they carry
  # nav/aria-current semantics rather than the ARIA tabs pattern — declaring
  # role="tab" would promise arrow-key navigation and in-place panel swapping
  # that full-page links can't deliver.
  # People live in the comparison drawer now, so the only bottom-pane view
  # left is the wall — one toggle, not a tab set. Clicking the active
  # toggle closes it.
  def wall_toggle
    active = @view == "wall"
    classes = if active
      "bg-gray-900 text-white dark:bg-white dark:text-gray-900"
    else
      "border border-gray-300 dark:border-gray-600 text-gray-900 dark:text-white " \
        "hover:bg-gray-50 dark:hover:bg-gray-800"
    end
    div(class: "mt-6") do
      a(
        href: drill_in_path(view: active ? nil : "wall"),
        aria: { expanded: active.to_s },
        class: "inline-flex min-h-11 items-center rounded-md px-3 py-2 text-sm font-medium #{classes}"
      ) { "Feedback / Evidence wall" }
    end
  end

  # Rebuilds the drill-in URL with the given view, preserving the opened
  # person, the pins, and (within the wall) the active filters.
  def drill_in_path(view:, person: opened_person_id, person_level: :current,
                    person_action: nil, pins: @pin_ids, filters: @wall_filters)
    # Focus belongs to the OPEN card: a link that opens a different person
    # (a grid dot, an unrated-sentence name) must start at THEIR assessed
    # level, not inherit this card's focused ordinal.
    person_level = (@person_focus_ordinal if person == opened_person_id) if person_level == :current
    query = {}
    query[:person] = person if person.present?
    # Focus and open-form state belong to the open card — never carried
    # once the card is closed.
    if person.present?
      query[:person_level] = person_level if person_level
      query[:person_action] = person_action if person_action
    end
    query[:pins] = pins if pins.any?
    query[:view] = view if view
    # Filters ride every link, not just wall→wall, so stepping out to a
    # person card and back returns to the wall the room was reading.
    query[:wall_level] = filters[:level] if filters[:level]
    query[:wall_valence] = filters[:valence] if filters[:valence]
    query[:wall_rater] = filters[:rater_id] if filters[:rater_id]
    calibration_session_capability_path(@session, @stats[:capability][:stable_id], query)
  end

  def opened_person_id
    @person_card&.dig(:dot, :person_id)
  end

  # A note typed here is ABOUT what's on screen, so it carries the
  # capability, and `from` routes the redirect back to this drill-in
  # instead of the session page. The opened person rides the pane's own
  # `person` param, which `stampState` refreshes at submit time.
  def note_fields
    [ [ "capability_stable_id", @stats[:capability][:stable_id] ], [ "from", "drill_in" ] ]
  end

  # Rides the outcome POSTs (flag / revisit) so their redirects can restore
  # the whole working state — which pane was open, the opened person, the
  # compare pins, the wall's filters. An outcome recorded mid-comparison
  # must not reset the room's screen.
  def state_passthrough_fields
    # Tagged `pane_state` so `calibration-pane#stampState` can SWEEP these
    # before re-stamping from the live URL. Without the sweep a value the
    # room cleared inside the frame (an unpinned person, a closed card)
    # would ride the POST from this page-load snapshot and come back.
    tag = { pane_state: "true" }
    input(type: "hidden", name: "person", value: opened_person_id, data: tag) if opened_person_id.present?
    if opened_person_id.present? && @person_focus_ordinal
      input(type: "hidden", name: "person_level", value: @person_focus_ordinal, data: tag)
    end
    @pin_ids.each { |id| input(type: "hidden", name: "pins[]", value: id, data: tag) }
    input(type: "hidden", name: "view", value: @view, data: tag) if @view
    { wall_level: @wall_filters[:level], wall_valence: @wall_filters[:valence],
      wall_rater: @wall_filters[:rater_id] }.each do |name, value|
      input(type: "hidden", name: name.to_s, value: value, data: tag) if value.present?
    end
  end

  # ── Evidence wall (§d — the norming surface) ──

  def wall_section
    div(class: "mt-3", id: "calibration-wall") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex flex-wrap items-baseline justify-between gap-2") do
            h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
              "Feedback / Evidence — #{@stats[:capability][:name]}"
            end
            # `data-wall-total` is the machine-readable count. The visible
            # text is not assertable: "1 item" is a substring of the utility
            # class `min-h-11 items-center`, so a body-substring check on it
            # passes on pages with no wall at all.
            p(class: "text-xs text-gray-600 dark:text-gray-300",
              data: { wall_total: @wall[:total] }) do
              "#{@wall[:total]} #{'item'.pluralize(@wall[:total])} across the population"
            end
          end
          wall_filters_form
          if @wall[:groups].empty?
            p(class: "mt-4 text-sm text-gray-600 dark:text-gray-300") do
              "No feedback / evidence linked to this capability for the population" \
                "#{' with these filters' if wall_filtered?}."
            end
          else
            @wall[:groups].each { |group| wall_level_group(group) }
          end
        end
      end
    end
  end

  def wall_filtered?
    @wall_filters.values.any?(&:present?)
  end

  def wall_filters_form
    form(action: calibration_session_capability_path(@session, @stats[:capability][:stable_id]),
         method: "get", class: "mt-3 flex flex-wrap items-end gap-2",
         data: { action: "submit->calibration-pane#submitFilters" }) do
      input(type: "hidden", name: "view", value: "wall")
      input(type: "hidden", name: "person", value: opened_person_id) if opened_person_id.present?
      if opened_person_id.present? && @person_focus_ordinal
        input(type: "hidden", name: "person_level", value: @person_focus_ordinal)
      end
      @pin_ids.each { |id| input(type: "hidden", name: "pins[]", value: id) }

      wall_filter_select("wall_level", "Level", @wall[:level_ordinals].map { |o| [ "L#{o}", o ] },
                         @wall_filters[:level])
      wall_filter_select("wall_valence", "Valence",
                         EvidenceLink::VALENCES.map { |v| [ valence_label(v), v ] },
                         @wall_filters[:valence])
      wall_filter_select("wall_rater", "Rater",
                         @wall[:rater_ids].map { |id| [ rater_name(id), id ] },
                         @wall_filters[:rater_id])
      button(
        type: "submit",
        class: "inline-flex min-h-11 items-center rounded-md border border-gray-300 " \
               "dark:border-gray-600 px-3 py-2 text-sm text-gray-900 dark:text-white " \
               "hover:bg-gray-50 dark:hover:bg-gray-800"
      ) { "Filter" }
    end
  end

  def wall_filter_select(name, label_text, options, selected)
    div do
      label(for: "wall-filter-#{name}",
            class: "block text-xs font-medium text-gray-600 dark:text-gray-300") { label_text }
      select(
        id: "wall-filter-#{name}", name: name,
        # min-w so the short-option Level select lines up with its siblings
        # instead of collapsing to the width of "All".
        class: "mt-0.5 min-h-11 min-w-32 rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-2 text-sm text-gray-900 dark:text-white"
      ) do
        option(value: "") { "All" }
        options.each do |text, value|
          option(value: value, selected: selected.to_s == value.to_s ? "selected" : nil) { text.to_s }
        end
      end
    end
  end

  def wall_level_group(group)
    div(class: "mt-4") do
      h3(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300 " \
                "border-b border-gray-200 dark:border-gray-700 pb-1") { "L#{group[:ordinal]}" }
      ul(class: "mt-2 space-y-2") do
        group[:items].each { |item| wall_item(item) }
      end
    end
  end

  # One wall item: the calibration shape (rating stamp, valence, relation,
  # rater) above the person and what was actually written about them.
  def wall_item(item)
    li(
      class: "rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2",
      data: { person_id: item[:person_id] }
    ) do
      div(class: "flex flex-wrap items-center gap-2") do
        rating_pill("Mgr", item[:frequency], carried: item[:frequency_carried])
        valence_badge(item[:valence])
        span(class: "text-xs text-gray-600 dark:text-gray-300") do
          plain RELATION_LABELS.fetch(item[:relation], item[:relation])
          plain " · #{rater_name(item[:rater_id])}'s report" if item[:rater_id]
        end
      end
      div(class: "mt-1.5") do
        p(class: "text-xs font-medium text-gray-900 dark:text-white") { item[:person_name] }
        p(class: "mt-0.5 text-sm text-gray-900 dark:text-white") { item[:content].truncate(280) }
        p(class: "mt-0.5 text-[11px] text-gray-600 dark:text-gray-300") do
          item[:recorded_at].strftime("%b %-d, %Y")
        end
      end
    end
  end

  # ── The comparison drawer (§e — the deliberate juxtaposition, now a
  # sticky bottom shelf) ──
  #
  # One presentation of a person, side by side: the INSPECTOR (the person
  # the room just clicked) in the left slot, pinned people beside it.
  # Sticky bottom-0 as the last element of the main column, so it rides
  # the viewport bottom while the room scrolls the grid — and the session
  # log at the page's right edge stays visible throughout. Cards scroll
  # internally; the collapse toggle drops the drawer to its header bar.
  def comparison_drawer
    inspector_pinned = opened_person_id && @pin_ids.include?(opened_person_id)
    cards = []
    @pinned_cards.each { |person_id, card| cards << [ card, person_id == opened_person_id ] }
    # The just-opened person APPENDS — pinned cards keep their positions,
    # so the row reads oldest-held to newest-opened.
    cards << [ @person_card, true ] if @person_card && !inspector_pinned
    return if cards.empty?

    comparison_drawer_chrome(pin_count: @pin_ids.size, max_pins: MAX_PINS) do
      cards.each { |card_data, inspector| drawer_card(card_data, inspector: inspector) }
    end
  end

  # One person, one card — inspector or pinned, same body. The inspector
  # carries the focus features (level focus, kebab, open form, Close);
  # a pinned card renders at its person's assessed level, and any chip
  # click promotes them to inspector at that level.
  def drawer_card(card_data, inspector:)
    dot = card_data[:dot]
    pinned = @pin_ids.include?(dot[:person_id])
    div(
      class: "min-w-[320px] max-w-[440px] flex-1 shrink-0 rounded-lg border bg-white dark:bg-gray-800 " \
             "p-3 h-full overflow-y-auto " \
             "#{pinned ? 'border-violet-500 ring-1 ring-violet-500' : 'border-gray-200 dark:border-gray-700'}",
      id: (inspector ? "calibration-person-card" : nil),
      data: { drawer_card: dot[:person_id] }
    ) do
      div(class: "flex flex-wrap items-start justify-between gap-2") do
        div do
          h2(class: "text-base font-semibold text-gray-900 dark:text-white") { dot[:name] }
          p(class: "mt-0.5 text-xs text-gray-600 dark:text-gray-300") do
            plain "L#{card_data[:ordinal]}"
            plain " · rated by #{rater_name(card_data[:rater_id])}" if card_data[:rater_id]
          end
        end
        div(class: "flex items-center gap-1") do
          person_card_kebab if inspector
          pin_toggle_link(dot, pinned: pinned)
          # ONE dismiss per card: ✕ unpins a pinned card (below), closes an
          # unpinned inspector (here) — same gesture, "remove this card".
          if inspector && !pinned
            a(
              href: drill_in_path(view: @view, person: nil),
              class: "inline-flex h-11 w-11 items-center justify-center text-lg " \
                     "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-md",
              aria: { label: "Close person card" }
            ) { "×" }
          end
        end
      end

      person_level_strip(card_data)
      person_level_panel(card_data, inspector: inspector)
      person_action_form if inspector
    end
  end

  # Pin holds a person in the drawer while the next one opens; the ✕ on a
  # pinned card releases the slot. Both stay on the current view —
  # pinning is a drawer gesture, not a navigation.
  def pin_toggle_link(dot, pinned:)
    if pinned
      a(
        href: drill_in_path(view: @view, pins: @pin_ids - [ dot[:person_id] ]),
        class: "inline-flex h-11 w-11 items-center justify-center text-lg " \
               "text-violet-700 dark:text-violet-300 hover:bg-violet-50 dark:hover:bg-violet-900/30 rounded-md",
        aria: { label: "Unpin #{dot[:name]} from the comparison drawer" }
      ) { "×" }
    elsif @pin_ids.size < MAX_PINS
      a(
        href: drill_in_path(view: @view, pins: @pin_ids + [ dot[:person_id] ]),
        class: "inline-flex min-h-11 items-center px-2 text-sm text-primary hover:underline",
        aria: { label: "Pin #{dot[:name]} to the comparison drawer" }
      ) { "Pin" }
    end
  end

  # ── The read-only per-level column (the assessment capability view,
  # adapted) ──
  #
  # A person can be rated above their level, so the card renders the whole
  # ladder for this capability: one chip per level in the assessment's
  # rating vocabulary (manager perspective — the judgments being
  # calibrated), focused initially at the assessed level. Chips are pane
  # links (`?person_level=`), so switching levels swaps the card in place
  # without scrolling the room.
  def person_level_strip(card_data)
    levels = card_data[:levels]
    return if levels.size <= 1

    div(class: "mt-3 overflow-x-auto") do
      # The inner padding keeps the focused chip's offset ring inside the
      # scroll wrapper instead of clipped at its edge.
      div(class: "flex items-start gap-1.5 p-1") do
        levels.each { |level| person_level_chip(card_data, level) }
      end
    end
  end

  def person_level_chip(card_data, level)
    ordinal = level[:ordinal]
    focused = ordinal == card_focus_ordinal(card_data)
    assessed = ordinal == card_data[:ordinal]
    fill, border, note = person_chip_appearance(card_data, ordinal)

    div(class: "flex flex-col items-center gap-0.5") do
      # The 44px tap target is the link; the visual chip is the inner span
      # (the grid dot's pattern). On a pinned card the click PROMOTES that
      # person to inspector at the clicked level.
      a(
        href: drill_in_path(view: @view, person: card_data[:dot][:person_id], person_level: ordinal),
        class: "inline-flex h-11 min-w-11 items-center justify-center",
        aria: { label: person_chip_label(level, note, assessed: assessed), current: focused ? "true" : nil }
      ) do
        span(
          class: "inline-flex h-9 min-w-11 items-center justify-center rounded-md border-2 px-1.5 " \
                 "text-[11px] font-semibold #{fill} #{border} " \
                 "#{'ring-2 ring-offset-2 ring-gray-900 dark:ring-white dark:ring-offset-gray-800' if focused}"
        ) { level[:code] }
      end
      if assessed
        span(class: "text-[9px] font-semibold tracking-wide text-gray-600 dark:text-gray-300") do
          "CURRENT"
        end
      end
    end
  end

  # The assessment chip vocabulary, manager perspective: solid palette fill
  # when rated, the lighter carried tint + dashed edge when inherited,
  # assumed-consistent blue below the assessed level, neutral above.
  def person_chip_appearance(card_data, ordinal)
    rating = card_data[:ratings_by_level][ordinal] || {}
    config = rating[:manager] && CONFIG[rating[:manager]]
    if config && rating[:manager_carried]
      [ "#{config[:chip_carried]} #{config[:chip_txt]}", config[:chip_carried_border],
        "#{config[:phrase]} (carried forward, unconfirmed)" ]
    elsif config
      [ "#{config[:chip_bg]} #{config[:chip_txt]}", "border-white dark:border-gray-800",
        config[:phrase] ]
    elsif ordinal < card_data[:ordinal]
      [ "bg-blue-300 dark:bg-blue-300 text-blue-950", "border-white dark:border-gray-800",
        "unrated — assumed consistent below the assessed level" ]
    else
      [ "bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-200",
        "border-white dark:border-gray-800", "unrated" ]
    end
  end

  def person_chip_label(level, note, assessed:)
    label = "L#{level[:ordinal]} — Manager: #{note}"
    label += " — assessed level" if assessed
    label
  end

  # The focused level's read-only cell: expectation text, both rating
  # pills, the revisit marker when this session already asked, and the
  # feedback / evidence linked at this level.
  def person_level_panel(card_data, inspector:)
    ordinal = card_focus_ordinal(card_data)
    rating = card_data[:ratings_by_level][ordinal] || {}

    div(class: "mt-3 border-t border-gray-100 dark:border-gray-800 pt-3") do
      p(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        "L#{ordinal}"
      end
      expectation = card_data[:expectations_by_level][ordinal]
      p(class: "mt-1 text-sm text-gray-900 dark:text-white") do
        expectation || "No expectation defined at this level for this capability."
      end

      div(class: "mt-3 flex flex-wrap gap-2") do
        rating_pill("Manager", rating[:manager], carried: rating[:manager_carried])
        rating_pill("Self", rating[:self], withheld: card_data[:self_withheld])
      end

      if card_data[:revisit_ordinals].include?(ordinal)
        p(class: "mt-3 text-xs font-medium text-amber-700 dark:text-amber-300") do
          plain "Revisit requested — it will appear in #{rater_name(card_data[:rater_id])}'s assessment activity."
        end
      end
      if @stats[:clarifications][ordinal].to_i.positive?
        div(class: "mt-2 text-xs font-medium text-amber-700 dark:text-amber-300") do
          "⚑ Flagged — #{@stats[:clarifications][ordinal]} open " \
            "#{'clarification'.pluralize(@stats[:clarifications][ordinal])} on the framework"
        end
      end

      card_examples(ordinal) if inspector
      evidence_section(card_data[:evidence_by_level][ordinal] || [], ordinal)
    end
  end

  # The cell's reference examples, on the card so "what does good look
  # like here" never needs a navigation away from the person under
  # discussion. Each example carries its own ⚑ (see #example_flag).
  # Inspector-only and collapsed: three pinned cards at the same level
  # would otherwise repeat the identical capability-level list (and its
  # flag forms) once per card inside 38vh scrollers.
  def card_examples(ordinal)
    groups = @stats[:illustrations]&.dig(ordinal)
    return if groups.blank?

    details(class: "mt-3") do
      summary(class: "inline-flex min-h-11 cursor-pointer items-center text-xs font-semibold " \
                     "uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        "Examples at L#{ordinal} (#{groups.sum { |group| group[:items].size }})"
      end
      example_groups(ordinal)
    end
  end

  # Level focus is inspector state; every other card sits at its person's
  # assessed level.
  def card_focus_ordinal(card_data)
    return focus_ordinal if card_data.equal?(@person_card)

    card_data[:ordinal]
  end

  def focus_ordinal
    @person_focus_ordinal || @person_card[:ordinal]
  end

  # The card's actions live in one kebab (the assessment strip's pattern):
  # "Request feedback / evidence…" (§f — when the room can't answer "what
  # did you see?", the resolution IS an evidence request) and "Ask the
  # rater to revisit…". Each item is a pane link (`?person_action=`) that
  # re-renders the card with that form open at the focused level — the
  # page's URL-driven state, no extra JS. Items only render when their
  # gates hold (live session, viewer entitlement, a rater to ask, no
  # duplicate revisit on this cell).
  def person_card_kebab
    request_ok = @can_flag && @request_candidates&.any?
    revisit_ok = @can_flag && @person_card[:rater_id] &&
                 !@person_card[:revisit_ordinals].include?(focus_ordinal)
    flag_ok = @can_flag && @stats[:clarifications][focus_ordinal].to_i.zero?
    return unless request_ok || revisit_ok || flag_ok

    render Components::Kit::Dropdown.new(align: :right) do |dropdown|
      dropdown.trigger(label: "Actions for #{@person_card[:dot][:name]}") do
        span(class: "inline-flex h-11 w-11 items-center justify-center rounded-md text-lg " \
                    "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700") do
          "⋮"
        end
      end
      dropdown.menu do
        person_kebab_item("Request feedback / evidence…", "request") if request_ok
        person_kebab_item("Ask #{rater_name(@person_card[:rater_id])} to revisit this rating…", "revisit") if revisit_ok
        person_kebab_item("⚑ Flag expectation as unclear…", "flag") if flag_ok
      end
    end
  end

  def person_kebab_item(label, action)
    a(
      href: drill_in_path(view: nil, person_action: action),
      role: "menuitem",
      class: "block px-4 py-2.5 text-sm text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700"
    ) { label }
  end

  # The form the kebab opened, rendered expanded under the focused-level
  # panel. Scoped to the FOCUSED level — the ask is about the cell on
  # screen, which may sit above the person's assessed level.
  def person_action_form
    case @person_action
    when "request" then request_evidence_section
    when "revisit" then revisit_section
    when "flag" then card_flag_section
    end
  end

  # The kebab's flag path — the same clarification the column header's ⚑
  # raises, opened from the card and scoped to the focused level.
  def card_flag_section
    return unless @can_flag
    return if @stats[:clarifications][focus_ordinal].to_i.positive?

    div(class: "mt-4 border-t border-gray-100 dark:border-gray-800 pt-3") do
      p(class: "text-xs font-medium text-gray-600 dark:text-gray-300") do
        "Flag the L#{focus_ordinal} expectation as unclear"
      end
      expectation_flag_form(focus_ordinal, field_id: "flag-reason-card")
    end
  end

  def request_evidence_section
    return unless @can_flag && @request_candidates

    div(class: "mt-4 border-t border-gray-100 dark:border-gray-800 pt-3") do
      if @request_candidates.empty?
        p(class: "text-xs text-gray-600 dark:text-gray-300") do
          "No colleagues to ask about this behaviour — org neighbours appear here."
        end
      else
        request_evidence_form
      end
    end
  end

  def request_evidence_form
    div do
      p(class: "text-xs font-medium text-gray-600 dark:text-gray-300") do
        "Request feedback / evidence about #{@person_card[:dot][:name]} at L#{focus_ordinal}"
      end
      form(
        action: calibration_session_evidence_requests_path(@session),
        method: "post",
        class: "mt-2 max-w-lg space-y-2",
        # Breaks out of the pane frame so the flash — success or refusal —
        # renders in the layout (the revisit form's rule).
        data: { turbo_frame: "_top" }
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "person_id", value: @person_card[:dot][:person_id])
        input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
        input(type: "hidden", name: "level_ordinal", value: focus_ordinal)
        state_passthrough_fields
        select(
          id: "evidence-request-requestee", name: "requestee_person_id", required: true,
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          aria: { label: "Who to ask for feedback / evidence" }
        ) do
          option(value: "") { "Who to ask…" }
          @request_candidates.each { |candidate| requestee_option(candidate) }
        end
        textarea(
          id: "evidence-request-message", name: "message", rows: "2",
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          placeholder: "Why the room is asking — e.g. \u201cnobody could answer what good looks like here\u201d",
          aria: { label: "Message to the person being asked" }
        )
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-emerald-700 px-3 py-2 text-sm " \
                 "font-semibold text-white hover:bg-emerald-800 transition-colors"
        ) { "Send request" }
      end
    end
  end

  # One option per org neighbour; a pending ask on this exact cell greys
  # the person out rather than hiding them ("already asked" beats
  # silently missing).
  def requestee_option(candidate)
    label = "#{candidate.person.name} — #{candidate.relation}"
    label += " · already asked" if candidate.already_requested
    option(value: candidate.person.id, disabled: candidate.already_requested) { label }
  end

  # Value-free revisit ask, on the card because discussing the dot is what
  # earns the outcome. Only for in-session raters (reference points are
  # exempt), only while live; one ask per cell per session — the focused
  # level's marker renders in the level panel, so this only ever opens for
  # a cell without one.
  def revisit_section
    return unless @can_flag && @person_card[:rater_id]
    return if @person_card[:revisit_ordinals].include?(focus_ordinal)

    div(class: "mt-4 border-t border-gray-100 dark:border-gray-800 pt-3") do
      revisit_form
    end
  end

  def revisit_form
    div do
      p(class: "text-xs font-medium text-gray-600 dark:text-gray-300") do
        "Ask #{rater_name(@person_card[:rater_id])} to revisit this rating at L#{focus_ordinal}"
      end
      form(
        action: calibration_session_rating_revisits_path(@session),
        method: "post",
        class: "mt-2 max-w-lg space-y-2",
        # Breaks out of the pane frame: the outcome's flash — including the
        # alert when the ask is rejected — renders in the layout OUTSIDE the
        # frame, so a frame-scoped submit would swallow it and the failure
        # would look like nothing happened.
        data: { turbo_frame: "_top" }
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "person_id", value: @person_card[:dot][:person_id])
        input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
        input(type: "hidden", name: "level_ordinal", value: focus_ordinal)
        state_passthrough_fields
        textarea(
          id: "revisit-note", name: "note", rows: "2", required: true,
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          placeholder: "The room's note — what the discussion surfaced (never a target rating)",
          aria: { label: "Discussion note for the revisit request" }
        )
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-amber-600 px-3 py-2 text-sm " \
                 "font-semibold text-white hover:bg-amber-700 transition-colors"
        ) { "Request revisit" }
      end
    end
  end

  # `carried:` renders the palette's dashed-outline variant — the same
  # "carried forward, unconfirmed" signal the assessment pills use — and
  # says so in the title, since the dash alone is decoration.
  # `withheld` is NOT "unrated": the viewer isn't entitled to this person's
  # assessment (AssesseeVisibility), so their self-rating is hidden. Saying
  # so beats a blank that reads as data.
  def rating_pill(label, frequency, carried: false, withheld: false)
    config = frequency && CONFIG[frequency]
    classes = if config
      carried ? config[:pill_carried] : config[:pill_bg]
    else
      "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"
    end
    phrase = if withheld
      "not shown"
    else
      config ? config[:phrase] : "unrated"
    end
    title = if withheld
      "Hidden — you don't have access to this person's assessment"
    elsif carried
      "Carried forward from the previous cycle, not confirmed this one"
    end
    span(
      class: "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-medium #{classes}",
      title: title
    ) do
      plain "#{label}: #{phrase}"
      if carried
        span(class: "ml-1 font-normal") { "· carried" }
      end
    end
  end

  def evidence_section(items, ordinal)
    div(class: "mt-4") do
      h3(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        "Feedback / Evidence at L#{ordinal}"
      end
      if items.empty?
        p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
          plain "None linked — if the room can't answer “what did you see?”, that is the finding."
        end
      else
        ul(class: "mt-2 space-y-3") do
          items.each { |item| evidence_row(item) }
        end
      end
    end
  end

  def evidence_row(item)
    li(class: "rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2") do
      div(class: "flex flex-wrap items-center gap-2") do
        valence_badge(item[:valence])
        span(class: "text-xs text-gray-600 dark:text-gray-300") do
          plain RELATION_LABELS.fetch(item[:relation], item[:relation])
          plain " · "
          plain item[:recorded_at].strftime("%b %-d, %Y")
        end
      end
      p(class: "mt-1.5 text-sm text-gray-900 dark:text-white") { item[:content].truncate(280) }
    end
  end

  def rater_label(row)
    row[:rater_id] ? rater_name(row[:rater_id]) : "Other raters"
  end

  def rater_name(rater_id)
    person_name(rater_id)
  end
end
