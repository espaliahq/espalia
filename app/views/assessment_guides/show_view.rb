# frozen_string_literal: true

# "How assessments work" — an illustrated walk through one assessment cycle:
# set up, rate and gather feedback, align, close. Every value on the page is
# an example; the chips and colours are the assessment screen's own, so what
# a person learns here is what they will see there.
class Views::AssessmentGuides::ShowView < Views::Base
  include Views::Assessments::Concerns::ScoreScale
  include Views::Evidence::Valence

  Palette = Views::Assessments::FrequencyPalette

  # Stroke paths on a 24×24 grid. One-off glyphs for this page, so they stay
  # out of the shared sprite.
  ICONS = {
    grid: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
    star: "M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z",
    merge: "M4 6h5l3 6 3-6h5M12 12v8M9 17l3 3 3-3",
    flag: "M5 21V4M5 4h11l-2 4 2 4H5",
    user: "M12 12a4 4 0 100-8 4 4 0 000 8zM4 21c1.5-4 4.5-6 8-6s6.5 2 8 6",
    users: "M9 11.5a3.5 3.5 0 100-7 3.5 3.5 0 000 7zM2.5 20c1-3.5 3.5-5 6.5-5s5.5 1.5 6.5 5" \
           "M17 11.8a2.8 2.8 0 100-5.6M16 14.5c2.6 0 4.6 1.4 5.5 4.5",
    shield: "M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z",
    spark: "M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6",
    check: "M5 12.5l4.5 4.5L19 7.5",
    lock: "M6 11h12a2 2 0 012 2v6a2 2 0 01-2 2H6a2 2 0 01-2-2v-6a2 2 0 012-2zM8 11V8a4 4 0 018 0v3",
    eye: "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 15a3 3 0 100-6 3 3 0 000 6z",
    message: "M4 5h16v11H9l-5 4z",
    cycle: "M20 11a8 8 0 00-14.3-4.9L4 8M4 3v5h5M4 13a8 8 0 0014.3 4.9L20 16M20 21v-5h-5"
  }.freeze

  ACTORS = {
    you: { label: "You", icon: :user, mark: "mark-category-6" },
    manager: { label: "Your manager", icon: :shield, mark: "mark-category-1" },
    colleagues: { label: "Colleagues", icon: :users, mark: "mark-category-5" },
    admin: { label: "Admin / HR", icon: :grid, mark: "mark-category-4" },
    growthos: { label: Rails.application.config.x.product_name, icon: :spark, mark: nil }
  }.freeze

  STATIONS = [
    { anchor: "setup", icon: :grid, title: "Set up", blurb: "Your role, your level, your cycle.", status: "enrolled" },
    { anchor: "rate", icon: :star, title: "Rate & gather", blurb: "Two views, plus feedback.", status: "started" },
    { anchor: "align", icon: :merge, title: "Align", blurb: "Talk it through. Agree each cell.", status: "aligning → aligned" },
    { anchor: "close", icon: :flag, title: "Close", blurb: "Your record, ready for next time.", status: "concluded" }
  ].freeze

  STATUSES = [
    [ "enrolled", "in the cycle" ],
    [ "started", "first real rating" ],
    [ "aligning", "ratings locked" ],
    [ "aligned", "record agreed" ],
    [ "concluded", "cycle closed" ]
  ].freeze

  RULES = [
    { icon: :eye, title: "Your manager's view waits",
      body: "Your manager sees your ratings as you go. You see theirs once alignment starts." },
    { icon: :message, title: "Feedback informs, never scores",
      body: "It shapes the conversation. The score comes from ratings alone." },
    { icon: :shield, title: "One person drives alignment",
      body: "Only your reporting manager starts, completes or re-opens it." },
    { icon: :check, title: "Carried isn't confirmed",
      body: "Last cycle's ratings at your level and above show dashed until you say they still hold." }
  ].freeze

  # The example in the "score unlocks" ring.
  EXAMPLE_LEVEL_SIZE = 12
  # The example score's state: 132% is meeting E3 and a third of E4.
  EXAMPLE_STATE = :performing

  CARD = "rounded-2xl border border-default bg-overlay shadow-raised p-5 sm:p-6"
  MUTED = "text-muted"
  EYEBROW = "text-xs font-bold uppercase tracking-widest text-brand"
  CARD_TITLE = "text-xs font-semibold uppercase tracking-wider text-muted mb-4"
  HERE_CELL = "border-brand bg-brand-subtle"
  PLAIN_CELL = "border-default bg-subtle"

  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(user: nil, current_tenant: nil, tenants: [])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(class: "max-w-6xl mx-auto") do
        hero
        journey
        setup_phase
        rate_phase
        align_phase
        close_phase
        status_band
        rules
        p(class: "mt-10 text-xs #{MUTED}") do
          "Example values are illustrative. Levels, thresholds and labels follow your organisation's framework."
        end
      end
    end
  end

  private

  # ---- Page frame ----------------------------------------------------------

  def hero
    header(class: "relative overflow-hidden rounded-3xl border border-default bg-overlay px-6 pt-10 pb-20 sm:px-10") do
      div(class: "pointer-events-none absolute -top-24 -right-24 h-72 w-72 rounded-full bg-brand-muted blur-3xl",
        aria: { hidden: "true" })
      div(class: "pointer-events-none absolute -bottom-32 -left-16 h-64 w-64 rounded-full bg-brand-subtle blur-3xl",
        aria: { hidden: "true" })
      div(class: "relative") do
        p(class: EYEBROW) { "How assessments work" }
        h1(class: "mt-3 text-3xl sm:text-5xl font-extrabold tracking-tight leading-tight text-default") do
          plain "One cycle. Four steps."
          br
          span(class: "text-brand") { "One honest picture" }
          plain " of how you're growing."
        end
        p(class: "mt-4 max-w-2xl text-base sm:text-lg #{MUTED}") do
          "Each cycle, you and your manager rate the same behaviours, gather feedback from colleagues, " \
            "then sit down together and agree what's true. Here's the whole journey."
        end
        ul(class: "mt-6 flex flex-wrap gap-2", aria: { label: "Who takes part" }) do
          ACTORS.each_key do |key|
            li(class: "inline-flex items-center gap-2 rounded-full border border-default bg-subtle " \
                      "py-1 pl-1 pr-3 text-sm text-default") do
              avatar(key)
              plain ACTORS[key][:label]
            end
          end
        end
      end
    end
  end

  def journey
    nav(aria: { label: "The four steps" },
      class: "relative -mt-12 mx-2 sm:mx-6 #{CARD}") do
      div(class: "hidden lg:block absolute left-[calc(12.5%+1rem)] right-[calc(12.5%+1rem)] top-16 " \
                 "border-t-2 border-dashed border-emphasized", aria: { hidden: "true" })
      ol(class: "relative grid gap-6 sm:grid-cols-2 lg:grid-cols-4") do
        STATIONS.each_with_index { |station, index| station(station, index + 1) }
      end
    end
  end

  def station(station, number)
    li(class: "relative") do
      # A native jump, so the browser sets :target and honours scroll-margin.
      a(href: "##{station[:anchor]}", data: { turbo: "false" },
        class: "group flex lg:flex-col items-center gap-4 lg:gap-3 rounded-xl p-2 lg:text-center " \
               "hover:bg-overlay-hover") do
        # The ring punches the dashed line out behind the station
        span(class: "relative grid h-16 w-16 shrink-0 place-items-center rounded-full bg-overlay " \
                    "text-brand ring-4 ring-(--gos-surface-overlay) border-2 border-brand") do
          glyph(station[:icon], "h-7 w-7")
          span(class: "absolute -top-1 -right-1 grid h-6 w-6 place-items-center rounded-full bg-inverse " \
                      "text-xs font-bold text-inverse") { number.to_s }
        end
        span(class: "min-w-0") do
          span(class: "block font-semibold text-default group-hover:underline") { station[:title] }
          span(class: "block text-sm #{MUTED}") { station[:blurb] }
          code(class: "mt-2 inline-block rounded-md border border-default bg-subtle " \
                      "px-2 py-0.5 text-xs text-muted") { station[:status] }
        end
      end
    end
  end

  # A step: copy on one side, illustration on the other. `flip` puts the
  # illustration first on wide screens so the page zig-zags.
  def phase(anchor:, number:, title:, lead:, steps:, flip: false, &illustration)
    section(id: anchor, class: "scroll-mt-6 pt-16", aria: { labelledby: "#{anchor}-heading" }) do
      div(class: "grid items-center gap-8 lg:grid-cols-2 lg:gap-12") do
        div do
          p(class: EYEBROW) { "Step #{number}" }
          h2(id: "#{anchor}-heading",
            class: "mt-2 text-2xl sm:text-3xl font-bold tracking-tight text-default") { title }
          p(class: "mt-3 text-base sm:text-lg #{MUTED}") { lead }
          ul(class: "mt-6 space-y-4") do
            steps.each do |actor, heading, detail|
              li(class: "flex gap-3") do
                avatar(actor)
                div do
                  p(class: "font-semibold text-default") { heading }
                  p(class: "text-sm #{MUTED}") { detail }
                end
              end
            end
          end
        end
        div(class: "space-y-4 #{'lg:order-first' if flip}", &illustration)
      end
    end
  end

  # ---- Step 1 --------------------------------------------------------------

  def setup_phase
    phase(
      anchor: "setup", number: 1,
      title: "The framework says what good looks like",
      lead: "Before anyone rates anything, #{product_name} knows your role, your level, " \
            "and the behaviours expected at each step of the ladder.",
      steps: [
        [ :admin, "Admin publishes the career framework",
          "Roles, levels, capabilities and the behaviour expected at each level." ],
        [ :growthos, "You're placed on the ladder",
          "Your role, level and manager come from your HR system or an admin." ],
        [ :admin, "Admin opens a cycle and enrols the cohort", "Everyone in it gets the same window to assess." ],
        [ :growthos, "Last cycle's ratings come with you",
          "Nothing starts blank. Carried ratings at your level and above wait for you to confirm them." ]
      ]
    ) { framework_slice }
  end

  def framework_slice
    levels = %w[E1 E2 E3 E4 E5]
    capabilities = [ "Critical Thinking", "Delivery", "Collaboration", "Systems Design" ]

    div(class: CARD) do
      h3(class: CARD_TITLE) { "Your slice of the framework" }
      div(class: "grid grid-cols-[6rem_repeat(5,minmax(0,1fr))] sm:grid-cols-[8rem_repeat(5,minmax(0,1fr))] " \
                 "gap-1.5 text-xs",
        role: "img", aria: { label: "Four capabilities across levels E1 to E5, with E3 highlighted as your level" }) do
        div
        levels.each do |code|
          div(class: "pb-1 text-center font-bold #{code == 'E3' ? 'text-brand' : MUTED}",
            data: { guide_level_header: true }) do
            plain code
            span(class: "hidden sm:inline") { " · you" } if code == "E3"
          end
        end
        capabilities.each do |name|
          div(class: "truncate self-center font-semibold text-default") { name }
          levels.each do |code|
            div(class: "h-7 rounded-md border #{code == 'E3' ? HERE_CELL : PLAIN_CELL}")
          end
        end
      end
      callout(:spark, "Each cell is one behaviour to rate. Your level's column is where the score is decided.")
    end
  end

  # ---- Step 2 --------------------------------------------------------------

  def rate_phase
    phase(
      anchor: "rate", number: 2, flip: true,
      title: "Two views, backed by feedback",
      lead: "You and your manager rate the same cells. Your manager sees your ratings as you go; " \
            "theirs stay hidden from you until alignment starts.",
      steps: [
        [ :you, "You rate yourself", "How often do you show this behaviour? Pick one of four words." ],
        [ :manager, "Your manager rates you",
          "Or a delegate closer to the work, if you're seconded to another team." ],
        [ :colleagues, "Colleagues share feedback",
          "Asked for or offered unprompted, pinned to a behaviour. It informs ratings; it never counts in the score." ],
        [ :growthos, "Your score unlocks once enough is rated",
          "Until then you see progress, not a verdict, so a fresh assessment never reads as a zero." ]
      ]
    ) do
      rating_scale
      level_strip
      unlock_ring
      feedback_cards
    end
  end

  def rating_scale
    div(class: CARD) do
      h3(class: CARD_TITLE) { "Four words, four colours" }
      ul(class: "grid grid-cols-2 sm:grid-cols-4 gap-2") do
        %w[none some occasional consistent].each do |key|
          config = Palette::CONFIG.fetch(key)
          li(class: "rounded-xl px-2 py-3 text-center #{config[:chip_bg]} #{config[:chip_txt]}") do
            span(class: "block text-sm font-bold") { config[:label] }
            span(class: "block text-xs opacity-80") { config[:phrase] == config[:label] ? "" : config[:phrase] }
          end
        end
      end
    end
  end

  # Your own ratings only: before alignment the manager's are hidden, so a
  # chip here never splits. The split belongs to step 3.
  def level_strip
    most = Palette::CONFIG.fetch("occasional")
    some = Palette::CONFIG.fetch("some")

    div(class: CARD) do
      h3(class: CARD_TITLE) { "Your Critical Thinking ratings, level by level" }
      div(class: "flex flex-wrap gap-2", role: "img",
        aria: { label: "E1 and E2 assumed met, E3 rated most of the time, E4 rated some of the time, E5 not rated" }) do
        chip("E1", fill: Views::Assessments::LevelChip::ASSUMED_CONSISTENT_BG)
        chip("E2", fill: Views::Assessments::LevelChip::ASSUMED_CONSISTENT_BG)
        chip("E3", fill: most[:chip_bg], tag: "YOU", focused: true)
        chip("E4", fill: some[:chip_bg])
        chip("E5", fill: "bg-neutral-subtle")
      end
      div(class: "mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs #{MUTED}") do
        legend_swatch(Views::Assessments::LevelChip::ASSUMED_CONSISTENT_BG, "Below your level: assumed met")
        legend_swatch("bg-neutral-subtle", "Grey: not rated yet")
      end
    end
  end

  def unlock_ring
    unlock_at = Views::Assessments::HeroSummary.unlock_target_for(EXAMPLE_LEVEL_SIZE)
    circumference = 2 * Math::PI * 40
    filled = circumference * unlock_at / EXAMPLE_LEVEL_SIZE

    div(class: "#{CARD} flex items-center gap-5") do
      svg(viewBox: "0 0 100 100", class: "h-24 w-24 shrink-0", role: "img",
        aria: { label: "#{unlock_at} of #{EXAMPLE_LEVEL_SIZE} capabilities rated" }) do |s|
        s.circle(cx: "50", cy: "50", r: "40", fill: "none", stroke_width: "10",
          class: "stroke-(--gos-neutral-subtle)")
        s.circle(cx: "50", cy: "50", r: "40", fill: "none", stroke_width: "10", stroke_linecap: "round",
          stroke_dasharray: circumference.round(1).to_s, stroke_dashoffset: (circumference - filled).round(1).to_s,
          transform: "rotate(-90 50 50)", class: "stroke-(--gos-border-brand)")
        s.text(x: "50", y: "53", text_anchor: "middle",
          class: "fill-current text-default text-[20px] font-extrabold") { "#{unlock_at}/#{EXAMPLE_LEVEL_SIZE}" }
        s.text(x: "50", y: "67", text_anchor: "middle",
          class: "fill-current text-muted text-[10px] font-semibold") { "RATED" }
      end
      div do
        p(class: "font-semibold text-default") { "Score unlocks at #{unlock_at}" }
        p(class: "text-sm #{MUTED}") do
          "While you're rating, the score waits until enough of your level is rated. There isn't enough to judge yet."
        end
      end
    end
  end

  def feedback_cards
    div(class: CARD) do
      h3(class: CARD_TITLE) { "Feedback, pinned to a behaviour" }
      ul(class: "space-y-3") do
        feedback_card("Broke the migration into three safe steps and wrote down why.",
          "demonstrated", "Critical Thinking · E3")
        feedback_card("Could pull stakeholders in earlier on cross-team work.",
          "growth_area", "Collaboration · E3")
      end
    end
  end

  def feedback_card(quote, valence, cell)
    li(class: "flex gap-3 rounded-xl border border-default bg-subtle p-3") do
      avatar(:colleagues)
      div(class: "text-sm") do
        p(class: "text-default") { "“#{quote}”" }
        p(class: "mt-1.5 flex flex-wrap items-center gap-2") do
          valence_badge(valence)
          span(class: "text-xs #{MUTED}") { cell }
        end
      end
    end
  end

  # ---- Step 3 --------------------------------------------------------------

  def align_phase
    phase(
      anchor: "align", number: 3,
      title: "Sit down together and agree what's true",
      lead: "Your manager starts alignment. Their ratings appear, both sets lock, and every cell " \
            "you both rated the same this cycle settles itself. The conversation covers what's left.",
      steps: [
        [ :manager, "Your manager starts alignment", "Only your reporting manager can." ],
        [ :growthos, "Matching cells agree themselves",
          "Same rating from both of you this cycle? It's settled before you meet. Carried ratings still need agreeing." ],
        [ :you, "You both settle the rest",
          "Either of you can record the agreed value. Split chips turn solid as you go, " \
          "and the score appears once every cell at your level is agreed." ],
        [ :manager, "Your manager marks it complete",
          "Only once every cell at your level is agreed. A mistake can be re-opened." ]
      ]
    ) do
      two_views_to_one
      completion_gate
    end
  end

  def two_views_to_one
    most = Palette::CONFIG.fetch("occasional")
    some = Palette::CONFIG.fetch("some")

    div(class: CARD) do
      h3(class: CARD_TITLE) { "From two views to one" }
      div(class: "flex items-start justify-center gap-4 sm:gap-6") do
        figure(class: "w-28 text-center") do
          chip("E4", fill: some[:chip_bg], top: most[:chip_bg], size: :lg)
          figcaption(class: "mt-2 text-xs #{MUTED}") { "You say Most. Your manager says Some." }
        end
        span(class: "mt-8 text-2xl #{MUTED}", aria: { hidden: "true" }) { "→" }
        figure(class: "w-28 text-center") do
          chip("E4", fill: most[:chip_bg], size: :lg)
          figcaption(class: "mt-2 text-xs #{MUTED}") { "You agree on Most. The chip turns solid." }
        end
      end
    end
  end

  def completion_gate
    div(class: CARD) do
      h3(class: CARD_TITLE) { "Ready to complete?" }
      ul(class: "space-y-2 text-sm text-default") do
        gate_item("9 cells agreed automatically", done: true)
        gate_item("2 cells agreed in conversation", done: true)
        gate_item("1 cell still to align", done: false)
      end
      div(class: "mt-4", aria: { hidden: "true" }) do
        render Components::Kit::Button.new(tone: :success, size: :sm, disabled: true) do
          glyph(:lock, "h-4 w-4")
          plain "Mark alignment complete"
        end
      end
      p(class: "mt-2 text-xs #{MUTED}") { "The button stays off until the last cell is agreed." }
    end
  end

  def gate_item(text, done:)
    li(class: "flex items-center gap-2.5") do
      if done
        span(class: "grid h-5 w-5 place-items-center rounded-full bg-brand-muted text-brand") do
          glyph(:check, "h-3 w-3", stroke_width: 3)
        end
      else
        span(class: "h-5 w-5 rounded-full border-2 border-dashed border-emphasized",
          aria: { hidden: "true" })
      end
      plain text
    end
  end

  # ---- Step 4 --------------------------------------------------------------

  def close_phase
    phase(
      anchor: "close", number: 4, flip: true,
      title: "A record you both stand behind",
      lead: "When the cycle closes, the agreed ratings become your record for the period. " \
            "They read on one scale, and they carry into the next cycle.",
      steps: [
        [ :admin, "Admin closes the cycle", "Everyone still enrolled when it closes is marked concluded and stays part of its history." ],
        [ :growthos, "Your score reads on one scale",
          "100% means meeting your level. 200% means demonstrating the next one." ],
        [ :growthos, "The next cycle starts where this one ended",
          "Agreed values seed both sides. You confirm what still holds and change what's moved." ]
      ]
    ) do
      score_card
      div(class: "flex items-center gap-4 rounded-2xl border border-default bg-brand-subtle p-4") do
        span(class: "text-brand") { glyph(:cycle, "h-8 w-8") }
        p(class: "text-sm text-default") do
          strong { "And round again. " }
          plain "The next cycle opens with this one's agreed record already in place."
        end
      end
    end
  end

  def score_card
    div(class: CARD) do
      h3(class: CARD_TITLE) { "Your score" }
      p(class: "flex flex-wrap items-baseline gap-x-3") do
        span(class: "text-4xl font-extrabold tracking-tight #{tone_text(EXAMPLE_STATE)}") { "132%" }
        span(class: "font-semibold text-default") { "#{state_label(EXAMPLE_STATE)} at E3" }
      end
      p(class: "mt-1 text-sm #{MUTED}") { "Meeting E3 in full, and 32% of the way to E4." }
      div(class: "relative mt-5 grid grid-cols-2 gap-1", aria: { hidden: "true" }) do
        span(class: "h-3.5 rounded-full #{tone_bar(EXAMPLE_STATE)}")
        span(class: "h-3.5 overflow-hidden rounded-full bg-neutral-subtle") do
          span(class: "block h-full w-[32%] #{tone_bar(EXAMPLE_STATE)}")
        end
        span(class: "absolute -top-1.5 left-[66%] h-6 w-1 -translate-x-1/2 rounded bg-inverse")
      end
      div(class: "mt-2 flex justify-between text-xs #{MUTED}") do
        span { "0%" }
        span { "100% · E3" }
        span { "200% · E4" }
      end
    end
  end

  # ---- Status and rules ----------------------------------------------------

  def status_band
    section(class: "mt-20 #{CARD}", aria: { labelledby: "status-heading" }) do
      p(class: EYEBROW) { "Behind the scenes" }
      h2(id: "status-heading", class: "mt-2 text-2xl font-bold tracking-tight text-default") do
        "Your status at every step"
      end
      p(class: "mt-2 #{MUTED}") do
        "Each person in a cycle moves through these statuses, and the cohort report counts them. " \
          "The pill on your assessment puts them in plainer words, from In Progress through to Aligned."
      end
      ol(class: "mt-6 flex flex-col sm:flex-row sm:flex-wrap sm:items-center gap-2") do
        STATUSES.each_with_index do |(name, meaning), index|
          li(class: "flex flex-col sm:flex-row items-center gap-2") do
            if index.positive?
              span(class: "text-muted", aria: { hidden: "true" }) do
                span(class: "sm:hidden") { "↓" }
                span(class: "hidden sm:inline") { "→" }
              end
            end
            div(class: status_pill_classes(name)) do
              span(class: "block font-semibold text-default") { name }
              span(class: "block text-xs #{MUTED}") { meaning }
            end
          end
        end
      end
      div(class: "mt-4 flex flex-wrap gap-2 text-sm #{MUTED}") do
        note_chip("aligned → aligning", "when your manager re-opens alignment")
        note_chip("withdrawn", "if you're removed from the cycle or leave")
      end
    end
  end

  def status_pill_classes(name)
    base = "w-full sm:w-auto rounded-xl border-2 px-4 py-2 text-center sm:min-w-28"
    case name
    when "aligning", "aligned" then "#{base} border-brand bg-brand-subtle"
    when "concluded" then "#{base} border-dashed border-emphasized"
    else "#{base} border-default bg-subtle"
    end
  end

  def note_chip(term, meaning)
    span(class: "rounded-full border border-default bg-subtle px-3 py-1") do
      strong(class: "text-default") { term }
      plain " #{meaning}"
    end
  end

  def rules
    section(class: "mt-16", aria: { labelledby: "rules-heading" }) do
      p(class: EYEBROW) { "Good to know" }
      h2(id: "rules-heading", class: "mt-2 text-2xl font-bold tracking-tight text-default") do
        "Four rules that keep it fair"
      end
      ul(class: "mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4") do
        RULES.each do |rule|
          li(class: CARD) do
            span(class: "mb-3 grid h-10 w-10 place-items-center rounded-xl bg-brand-subtle text-brand") do
              glyph(rule[:icon], "h-5 w-5")
            end
            h3(class: "font-semibold text-default") { rule[:title] }
            p(class: "mt-1 text-sm #{MUTED}") { rule[:body] }
          end
        end
      end
    end
  end

  # ---- Pieces --------------------------------------------------------------

  def avatar(key)
    actor = ACTORS.fetch(key)
    span(class: "grid h-7 w-7 shrink-0 place-items-center rounded-full bg-mark text-on-mark #{actor[:mark]}",
      title: actor[:label]) do
      glyph(actor[:icon], "h-4 w-4")
      span(class: "sr-only") { actor[:label] }
    end
  end

  # A level chip in the assessment screen's colours. `top` paints the
  # top-left half, which is how a split rating reads there.
  def chip(code, fill:, top: nil, tag: nil, focused: false, size: :md)
    dimensions = size == :lg ? "h-24 w-24 mx-auto rounded-2xl text-base" : "h-12 w-12 rounded-xl text-sm"
    ring = focused ? "ring-2 ring-offset-2 ring-(--gos-border-strong) ring-offset-(--gos-surface-overlay)" : ""

    span(class: "relative grid shrink-0 place-items-center overflow-hidden font-bold text-default " \
                "#{dimensions} #{fill} #{ring}") do
      span(class: "absolute inset-0 #{top}", style: "clip-path: polygon(0 0, 100% 0, 0 100%);") if top
      span(class: "relative rounded bg-overlay/85 text-default px-1.5") { code }
      if tag
        span(class: "absolute bottom-0 left-1/2 -translate-x-1/2 rounded-t bg-inverse px-1 " \
                    "text-[10px] font-bold tracking-wider text-inverse") { tag }
      end
    end
  end

  def legend_swatch(fill, label)
    span(class: "inline-flex items-center gap-1.5") do
      span(class: "h-2.5 w-2.5 rounded-sm #{fill}", aria: { hidden: "true" })
      plain label
    end
  end

  def callout(icon, text)
    div(class: "mt-4 flex items-center gap-3 rounded-xl bg-brand-subtle px-3 py-2.5 text-sm text-default") do
      span(class: "text-brand") { glyph(icon, "h-5 w-5") }
      plain text
    end
  end

  def glyph(name, classes, stroke_width: 2)
    svg(viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", stroke_width: stroke_width.to_s,
      stroke_linecap: "round", stroke_linejoin: "round", class: classes, aria: { hidden: "true" }) do |s|
      s.path(d: ICONS.fetch(name))
    end
  end
end
