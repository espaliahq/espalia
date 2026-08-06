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
  include Views::Evidence::ExamplesDisclosure
  include Views::CalibrationSessions::Glossary

  UNRATED_DOT = "border-2 border-gray-300 dark:border-gray-600"

  RELATION_LABELS = { "self" => "Self", "manager" => "Manager", "peer" => "Peer feedback" }.freeze

  MAX_PINS = CalibrationSessions::CapabilitiesController::MAX_COMPARE_PINS

  # @param session [CalibrationSession]
  # @param stats [Hash] DrillInStats result
  # @param people [Hash{String => Person}] rater people by id
  # @param person_card [Hash, nil] `{ dot:, ordinal:, rater_id:, evidence: }`
  # @param view [String, nil] bottom-pane view — "wall" / "compare" / nil (person card)
  # @param wall [Hash, nil] EvidenceWall result when view == "wall"
  # @param wall_filters [Hash] `{ level:, valence:, rater_id: }` echoes
  # @param compare_ids [Array<String>] pinned compare person_ids (URL-carried)
  # @param compare_cards [Hash{String => Hash}] person_id => PersonCard data
  # @param can_flag [Boolean] whether the viewer can ⚑ flag an expectation
  #   as unclear (facilitator/admin AND the session is live)
  def initialize(session:, stats:, people:, person_card:, can_flag: false,
                 view: nil, wall: nil, wall_filters: {}, compare_ids: [], compare_cards: {},
                 session_log: nil, can_note: false,
                 user: nil, current_tenant: nil, tenants: [])
    @session = session
    @stats = stats
    @people = people
    @person_card = person_card
    @can_flag = can_flag
    @session_log = session_log
    @can_note = can_note
    @view = view
    @wall = wall
    @wall_filters = wall_filters
    @compare_ids = compare_ids
    @compare_cards = compare_cards
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(
        class: "max-w-7xl mx-auto px-4 py-8 flex gap-6 items-start",
        data: {
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
          expectations_card
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

  def header_row
    div(class: "flex flex-wrap items-center gap-3") do
      div(class: "flex-1 min-w-0") do
        a(href: calibration_session_path(@session),
          class: "text-sm text-gray-600 dark:text-gray-300 hover:underline") { "← #{@session.name}" }
        div(class: "mt-1 flex flex-wrap items-baseline gap-x-3") do
          if @stats[:capability][:category_name]
            span(class: "text-xs font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300") do
              @stats[:capability][:category_name]
            end
          end
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @stats[:capability][:name] }
        end
      end
      if @session_log
        render Views::CalibrationSessions::LogPaneToggle.new(
          entry_count: @session_log[:entries].size
        )
      end
    end
  end

  def expectations_card
    div(class: "mt-5") do
      render Components::Kit::Card.new do |card|
        card.body do
          h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
            "What good looks like"
          end
          dl(class: "mt-2 space-y-2") do
            @stats[:ordinals].each do |ordinal|
              div(class: "flex gap-3") do
                dt(class: "shrink-0 w-8 text-sm font-semibold text-gray-900 dark:text-white") { "L#{ordinal}" }
                dd(class: "flex-1 text-sm text-gray-600 dark:text-gray-300") do
                  plain @stats[:expectations][ordinal] || "No expectation defined at this level."
                  illustrations_for(ordinal)
                  flag_affordance(ordinal)
                end
              end
            end
          end
        end
      end
    end
  end

  # The role illustrations under a level's canonical expectation, one
  # collapsed disclosure per role — the same "Examples (N)" affordance the
  # evidence dialog uses beside a behavioural expectation. The expectation
  # is what people are rated against and stays in view; the examples are
  # reference material one click away (a disagreement often turns out to be
  # two raters reading different ones).
  def illustrations_for(ordinal)
    groups = @stats[:illustrations]&.dig(ordinal)
    return if groups.blank?

    div(class: "mt-1.5 space-y-1") do
      groups.each do |group|
        div(class: "flex flex-wrap items-baseline gap-x-2") do
          span(class: "shrink-0 text-[11px] font-medium uppercase tracking-wide " \
                      "text-gray-600 dark:text-gray-300") { group[:role_name] }
          div(class: "min-w-0 flex-1") { examples_disclosure(group[:items]) }
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
      form(
        action: calibration_session_expectation_flags_path(@session),
        method: "post",
        class: "mt-2 max-w-lg space-y-2",
        # Outside the pane frame, so its carried state is refreshed from the
        # live URL at submit time rather than page-load time.
        data: { action: "submit->calibration-pane#stampState" }
      ) do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "capability_stable_id", value: @stats[:capability][:stable_id])
        input(type: "hidden", name: "level_ordinal", value: ordinal)
        state_passthrough_fields
        textarea(
          id: "flag-reason-#{ordinal}", name: "reason", rows: "2",
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
              plain "· click a dot to discuss"
            end
          end

          div(class: "mt-3 overflow-x-auto") do
            table(class: "w-full text-sm") do
              thead do
                tr(class: "text-left text-xs text-gray-600 dark:text-gray-300") do
                  th(class: "sticky left-0 z-[2] bg-white dark:bg-gray-800 py-1.5 pr-3 font-medium") do
                    "Rater"
                  end
                  @stats[:ordinals].each { |ordinal| th(class: "py-1.5 pr-3 font-medium") { "L#{ordinal}" } }
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
      href: drill_in_path(view: nil, person: dot[:person_id], compare: [], filters: {}),
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
    a(
      # Opening a dot returns to the person-card view but keeps the pins —
      # the room browses dots mid-comparison without losing the tray. The
      # grid sits OUTSIDE the pane frame, so this href freezes at whatever
      # the pins and filters were on page load; `pane_keep_state` tells the
      # pane controller to merge the live values in at click time.
      href: drill_in_path(view: nil, person: dot[:person_id], compare: [],
                          filters: {}),
      class: "inline-flex h-11 w-11 items-center justify-center",
      title: dot[:name],
      # Initials are the compact label; the accessible name carries the
      # person, since "BA" tells a screen-reader user nothing.
      aria: { label: "#{dot[:name]} — #{base}. Open to discuss." },
      data: { pane_keep_state: "true", person_id: dot[:person_id] }
    ) do
      span(
        class: "inline-flex h-7 w-7 items-center justify-center rounded-full " \
               "text-[10px] font-semibold #{dot_classes(dot)}"
      ) { initials(dot[:name]) }
    end
  end

  # Two letters, uppercased — the divergence board's convention.
  def initials(name)
    name.to_s.split.map(&:first).first(2).join.upcase
  end

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

  # ── Bottom pane: person card / evidence wall / compare tray ──

  # The pane lives in a Turbo Frame so switching panes, opening a dot, or
  # pinning replaces only this region — a full-page navigation would scroll
  # the room back to the top, hiding the very thing they just clicked.
  # `calibration_pane_controller` drives the frame's src and keeps the
  # browser URL in step (the matrix-frame pattern from the explorer and the
  # assessment views).
  def bottom_pane
    turbo_frame_tag("calibration-bottom-pane",
                    data: { calibration_pane_target: "frame" }) do
      tab_bar
      case @view
      when "wall" then wall_section
      when "compare" then compare_section
      else person_card_section if @person_card
      end
    end
  end

  # Every pane link preserves the other axes (opened person, pins, filters)
  # so switching views never loses the room's working state.
  #
  # These look like tabs but ARE links that navigate the page, so they carry
  # nav/aria-current semantics rather than the ARIA tabs pattern — declaring
  # role="tab" would promise arrow-key navigation and in-place panel swapping
  # that full-page links can't deliver.
  def tab_bar
    nav(class: "mt-6 flex flex-wrap items-center gap-2", aria: { label: "Capability views" }) do
      if @person_card
        tab_link("Person: #{@person_card[:dot][:name]}", drill_in_path(view: nil), active: @view.nil?)
      end
      tab_link("Feedback / Evidence wall", drill_in_path(view: "wall"), active: @view == "wall")
      if @compare_cards.any? || @view == "compare"
        # Count the cards actually rendered, not the requested pins — a pinned
        # id for someone with no dot on THIS capability renders nothing, and a
        # count that disagrees with the tray reads as a bug.
        tab_link("Compare (#{@compare_cards.size})", drill_in_path(view: "compare"),
                 active: @view == "compare")
      end
    end
  end

  def tab_link(label, href, active:)
    classes = if active
      "bg-gray-900 text-white dark:bg-white dark:text-gray-900"
    else
      "border border-gray-300 dark:border-gray-600 text-gray-900 dark:text-white " \
        "hover:bg-gray-50 dark:hover:bg-gray-800"
    end
    a(
      href: href, aria: { current: active ? "page" : nil },
      class: "inline-flex min-h-11 items-center rounded-md px-3 py-2 text-sm font-medium #{classes}"
    ) { label }
  end

  # Rebuilds the drill-in URL with the given view, preserving the opened
  # person, the compare pins, and (within the wall) the active filters.
  def drill_in_path(view:, person: opened_person_id, compare: @compare_ids, filters: @wall_filters)
    query = {}
    query[:person] = person if person.present?
    query[:compare] = compare if compare.any?
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
    @compare_ids.each { |id| input(type: "hidden", name: "compare[]", value: id, data: tag) }
    input(type: "hidden", name: "view", value: @view, data: tag) if @view
    { wall_level: @wall_filters[:level], wall_valence: @wall_filters[:valence],
      wall_rater: @wall_filters[:rater_id] }.each do |name, value|
      input(type: "hidden", name: name.to_s, value: value, data: tag) if value.present?
    end
  end

  # ── Evidence wall (§d — the norming surface) ──

  def wall_section
    div(class: "mt-3") do
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
      @compare_ids.each { |id| input(type: "hidden", name: "compare[]", value: id) }

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

  # ── Compare tray (§e — the deliberate juxtaposition) ──

  def compare_section
    div(class: "mt-3", id: "calibration-compare") do
      render Components::Kit::Card.new do |card|
        card.body do
          h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
            "Compare"
          end
          if @compare_cards.empty?
            p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
              "Pin 2–3 person cards (same level, divergent ratings, both backed is the classic) " \
                "to hold them side by side — open a dot and use “Pin to compare”."
            end
          else
            # Literal class names — Tailwind's scanner can't see interpolation
            # (framework-explorer.md Hard-Won Lesson 12).
            cols = { 1 => "md:grid-cols-1", 2 => "md:grid-cols-2", 3 => "md:grid-cols-3" }
            div(class: "mt-3 grid gap-4 #{cols.fetch([ @compare_cards.size, MAX_PINS ].min)}") do
              @compare_cards.each { |person_id, card_data| compare_card(person_id, card_data) }
            end
          end
        end
      end
    end
  end

  # A pinned mini person card.
  def compare_card(person_id, card_data)
    dot = card_data[:dot]
    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 p-3",
        data: { compare_card: person_id }) do
      div(class: "flex items-start justify-between gap-2") do
        div do
          h3(class: "text-sm font-semibold text-gray-900 dark:text-white") { dot[:name] }
          p(class: "text-xs text-gray-600 dark:text-gray-300") do
            plain "L#{card_data[:ordinal]}"
            plain " · rated by #{rater_name(card_data[:rater_id])}" if card_data[:rater_id]
          end
        end
        a(
          href: drill_in_path(view: "compare", compare: @compare_ids - [ person_id ]),
          class: "inline-flex h-11 min-w-11 items-center justify-center px-1 text-xs " \
                 "text-gray-600 dark:text-gray-300 hover:underline",
          aria: { label: "Unpin #{dot[:name]} from compare" }
        ) { "Unpin" }
      end
      div(class: "mt-2 flex flex-wrap gap-1.5") do
        rating_pill("Mgr", dot[:frequency], carried: dot[:carried])
        rating_pill("Self", dot[:self_frequency], withheld: dot[:self_withheld])
      end
      if card_data[:evidence].empty?
        p(class: "mt-3 text-xs text-gray-600 dark:text-gray-300") do
          "No feedback / evidence at this behaviour."
        end
      else
        ul(class: "mt-3 space-y-2") do
          card_data[:evidence].each { |item| evidence_row(item) }
        end
      end
    end
  end

  # Pin the opened person into the compare tray (capped at 3; the pinned
  # marker replaces the link once in). Pinning navigates straight to the
  # tray — the pin IS the "hold this one" gesture.
  def pin_to_compare_link(dot)
    if @compare_ids.include?(dot[:person_id])
      span(class: "inline-flex min-h-11 items-center px-2 text-xs font-medium " \
                  "text-gray-600 dark:text-gray-300") { "Pinned" }
    elsif @compare_ids.size < MAX_PINS
      a(
        href: drill_in_path(view: "compare", compare: @compare_ids + [ dot[:person_id] ]),
        class: "inline-flex min-h-11 items-center px-2 text-sm text-primary hover:underline",
        aria: { label: "Pin #{dot[:name]} to compare" }
      ) { "Pin to compare" }
    end
  end

  # The opened member's card.
  def person_card_section
    dot = @person_card[:dot]
    div(class: "mt-6", id: "calibration-person-card") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex flex-wrap items-start justify-between gap-3") do
            div do
              h2(class: "text-lg font-semibold text-gray-900 dark:text-white") { dot[:name] }
              p(class: "mt-0.5 text-sm text-gray-600 dark:text-gray-300") do
                plain "L#{@person_card[:ordinal]}"
                plain " · rated by #{rater_name(@person_card[:rater_id])}" if @person_card[:rater_id]
              end
            end
            div(class: "flex items-center gap-1") do
              pin_to_compare_link(dot)
              a(
                href: drill_in_path(view: nil, person: nil),
                class: "inline-flex h-11 min-w-11 items-center justify-center px-2 text-sm " \
                       "text-gray-600 dark:text-gray-300 hover:underline",
                aria: { label: "Close person card" }
              ) { "Close" }
            end
          end

          div(class: "mt-3 flex flex-wrap gap-2") do
            rating_pill("Manager", dot[:frequency], carried: dot[:carried])
            rating_pill("Self", dot[:self_frequency], withheld: dot[:self_withheld])
          end

          evidence_section
          revisit_section
        end
      end
    end
  end

  # Value-free revisit ask, on the card because discussing the dot is what
  # earns the outcome. Only for in-session raters (reference points are
  # exempt), only while live; one ask per cell per session.
  def revisit_section
    return unless @person_card[:rater_id]

    div(class: "mt-4 border-t border-gray-100 dark:border-gray-800 pt-3") do
      if @person_card[:revisit_requested]
        p(class: "text-xs font-medium text-amber-700 dark:text-amber-300") do
          plain "Revisit requested — it will appear in #{rater_name(@person_card[:rater_id])}'s assessment activity."
        end
      elsif @can_flag
        revisit_form
      end
    end
  end

  def revisit_form
    details do
      summary(
        class: "inline-flex min-h-11 cursor-pointer items-center text-xs font-medium " \
               "text-gray-600 dark:text-gray-300 hover:text-amber-700 dark:hover:text-amber-300"
      ) { "Ask #{rater_name(@person_card[:rater_id])} to revisit this rating" }
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
        input(type: "hidden", name: "level_ordinal", value: @person_card[:ordinal])
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

  def evidence_section
    div(class: "mt-4") do
      h3(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        "Feedback / Evidence at this behaviour"
      end
      if @person_card[:evidence].empty?
        p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
          plain "None linked — if the room can't answer “what did you see?”, that is the finding."
        end
      else
        ul(class: "mt-2 space-y-3") do
          @person_card[:evidence].each { |item| evidence_row(item) }
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
    @people[rater_id]&.name || "Unknown"
  end
end
