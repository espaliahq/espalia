# frozen_string_literal: true

# Assessment dashboard listing the current user's framework assignments,
# their direct reports' assessments (manager view), and — when they manage
# managers — a view-only skip-level section for the rest of their subtree.
#
class Views::Assessments::IndexView < Views::Base
  # Per-side completion state → [badge variant, label].
  SIDE_STATES = {
    complete: [ :success, "Complete" ],
    in_progress: [ :warning, "In progress" ],
    to_confirm: [ :to_confirm, "To confirm" ],
    not_started: [ :default, "Not started" ]
  }.freeze

  # @param assignments [Array<PersonFrameworkAssignment>] own assignments
  # @param report_assignments [Array<PersonFrameworkAssignment>] direct reports
  # @param skip_level_assignments [Array<PersonFrameworkAssignment>] current page of reports deeper in the viewer's subtree (view-only)
  # @param skip_level_pagy [Pagy::Offset, nil] pagination for the skip-level section
  # @param report_people [Hash{String => Person}] preloaded person records by ID (direct + skip-level)
  # @param open_cycles [Hash{Array(String, String) => AssessmentCycle}] preloaded open cycles keyed by [framework_id, person_id]
  # @param card_statuses [Hash{Array(String, String) => Hash}] per-card status keyed by [framework_id, person_id]
  # @param explorations [Hash{String => Array<Assessments::OpenExplorations::Entry>}] open declared
  #   explorations keyed by assignment id
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignments:, report_assignments: [], skip_level_assignments: [], skip_level_pagy: nil, report_people: {}, open_cycles: {}, card_statuses: {}, explorations: {}, user: nil, current_tenant: nil, tenants: [])
    @assignments = assignments
    @report_assignments = report_assignments
    @skip_level_assignments = skip_level_assignments
    @skip_level_pagy = skip_level_pagy
    @report_people = report_people
    @open_cycles = open_cycles
    @card_statuses = card_statuses
    @explorations = explorations
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      page_header
      assignments_list
      explorations_section
      report_assignments_section if @report_assignments.any?
      skip_level_assignments_section if @skip_level_assignments.any?
    end
  end

  private

  def page_header
    div(class: "mb-6") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "My Assessments" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "Self-assess your capabilities against your assigned framework."
      end
    end
  end

  def assignments_list
    if @assignments.empty?
      empty_state
    else
      div(class: "grid gap-4 sm:grid-cols-2 lg:grid-cols-3") do
        @assignments.each { |a| assignment_card(a) }
      end
    end
  end

  # The roles and levels the person is exploring (ADR-22), each a way into
  # the assessment read through it. Only their own — a report's show as a
  # chip on the team card.
  def explorations_section
    entries = @assignments.flat_map { |assignment| @explorations.fetch(assignment.id, []) }
    return if entries.empty?

    section(id: "explorations", class: "mt-10", aria: { labelledby: "explorations-heading" }) do
      h2(id: "explorations-heading", class: "text-xl font-bold text-gray-900 dark:text-white mb-1") { "Explorations" }
      p(class: "text-sm text-gray-600 dark:text-gray-300 mb-4") do
        "Roles and levels you're exploring. You and your manager see these; nobody else does."
      end
      ul(class: "grid gap-3 sm:grid-cols-2 lg:grid-cols-3") do
        entries.each { |entry| exploration_row(entry) }
      end
    end
  end

  def exploration_row(entry)
    li do
      a(href: assessment_path(entry.assignment, entry.lens_params),
        data: { exploration: entry.code },
        class: "block rounded-lg border border-sky-200 dark:border-sky-800 bg-white dark:bg-gray-900 p-4 " \
               "shadow-xs hover:border-sky-400 dark:hover:border-sky-600 transition-colors " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary") do
        p(class: "font-semibold text-gray-900 dark:text-white break-words") { entry.label }
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { exploration_meta(entry) }
      end
    end
  end

  # "4 of 10 rated · started by you · since 3 Oct"
  def exploration_meta(entry)
    exploration = entry.exploration
    starter = if exploration.started_by_id == exploration.person_id
      "you"
    else
      exploration.started_by&.name.to_s.split.first.presence || "someone"
    end
    [ rated_text(entry), "started by #{starter}", "since #{exploration.started_at.strftime('%-d %b')}" ]
      .compact.join(" · ")
  end

  def rated_text(entry)
    return if entry.total.nil?
    return "#{entry.total} #{'capability'.pluralize(entry.total)}" if entry.rated.nil?

    "#{entry.rated} of #{entry.total} rated"
  end

  def report_assignments_section
    div(class: "mt-10") do
      h2(class: "text-xl font-bold text-gray-900 dark:text-white mb-1") { "Team Assessments" }
      p(class: "text-sm text-gray-600 dark:text-gray-300 mb-4") do
        "Review and rate your direct reports\u2019 assessments."
      end
      div(class: "grid gap-4 sm:grid-cols-2 lg:grid-cols-3") do
        @report_assignments.each { |a| report_assignment_card(a) }
      end
    end
  end

  # Skip-level reports and deeper — the viewer can open these read-only
  # (the manager chain has full view access), but rating stays with each
  # person's own reporting manager. Cards share the report-card layout.
  # Paginated (pagy) — a senior manager's subtree can hold hundreds.
  def skip_level_assignments_section
    div(id: "skip-level-assessments", class: "mt-10") do
      h2(class: "text-xl font-bold text-gray-900 dark:text-white mb-1") { "Skip-Level Assessments" }
      p(class: "text-sm text-gray-600 dark:text-gray-300 mb-4") do
        "Assessments across your wider team — people reporting below your direct reports."
      end
      div(class: "grid gap-4 sm:grid-cols-2 lg:grid-cols-3") do
        @skip_level_assignments.each { |a| report_assignment_card(a) }
      end
      skip_level_pager if @skip_level_pagy && @skip_level_pagy.last > 1
    end
  end

  # Compact prev/next pager for the skip-level section. Links carry the
  # `skip_page` param plus the section anchor so paging keeps the viewer at
  # the section instead of jumping back to the top of the dashboard.
  def skip_level_pager
    pagy = @skip_level_pagy
    div(class: "mt-4 flex flex-wrap items-center justify-between gap-2") do
      span(class: "text-xs text-gray-500 dark:text-gray-400 tabular-nums") do
        "Showing #{pagy.from}–#{pagy.to} of #{pagy.count}"
      end
      div(class: "flex items-center gap-2") do
        skip_level_page_link("← Previous", pagy.previous)
        span(class: "text-xs text-gray-500 dark:text-gray-400 tabular-nums") do
          "Page #{pagy.page} of #{pagy.last}"
        end
        skip_level_page_link("Next →", pagy.next)
      end
    end
  end

  # @param label [String]
  # @param page [Integer, nil] nil renders a disabled placeholder
  def skip_level_page_link(label, page)
    shared = "inline-flex items-center rounded-md border px-2.5 py-1 text-xs font-medium"
    if page
      a(
        href: assessments_path(skip_page: page, anchor: "skip-level-assessments"),
        class: "#{shared} border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 " \
               "hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
      ) { label }
    else
      span(class: "#{shared} border-gray-200 dark:border-gray-700 text-gray-400 dark:text-gray-600") { label }
    end
  end

  def report_assignment_card(assignment)
    person = @report_people[assignment.person_id]
    cycle = @open_cycles[[ assignment.framework_id, assignment.person_id ]]

    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 p-5 shadow-xs") do
      div(class: "flex items-start justify-between") do
        div do
          h3(class: "text-lg font-semibold text-gray-900 dark:text-white") do
            person&.name || "Team Member"
          end
          p(class: "text-sm text-gray-600 dark:text-gray-300") do
            assignment.framework&.name || "Framework"
          end
          div(class: "mt-1 flex items-center gap-2") do
            if assignment.role
              render Components::Kit::Badge.new(assignment.role.name, variant: :info)
            end
            if assignment.level
              render Components::Kit::Badge.new(assignment.level.title, variant: :default)
            end
          end
        end
        status_badges(assignment, show_manager: true)
      end

      if cycle&.name.present?
        p(class: "mt-3 text-sm text-gray-600 dark:text-gray-300") { cycle.name }
      end
      exploration_chips(assignment)

      div(class: "mt-4") do
        a(
          href: assessment_path(assignment),
          class: "inline-flex items-center gap-1.5 rounded-md border border-gray-300 " \
                 "dark:border-gray-600 px-3 py-1.5 text-sm font-medium " \
                 "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 " \
                 "transition-colors"
        ) { "Review assessment" }
      end
    end
  end

  def assignment_card(assignment)
    cycle = @open_cycles[[ assignment.framework_id, assignment.person_id ]]

    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 p-5 shadow-xs") do
      div(class: "flex items-start justify-between") do
        div do
          h3(class: "text-lg font-semibold text-gray-900 dark:text-white") do
            assignment.framework&.name || "Framework"
          end
          div(class: "mt-1 flex items-center gap-2") do
            if assignment.role
              render Components::Kit::Badge.new(assignment.role.name, variant: :info)
            end
            if assignment.level
              render Components::Kit::Badge.new(assignment.level.title, variant: :default)
            end
          end
        end
        status_badges(assignment, show_manager: false)
      end

      if cycle&.name.present?
        p(class: "mt-3 text-sm text-gray-600 dark:text-gray-300") { cycle.name }
      end

      div(class: "mt-4") do
        if cycle
          a(
            href: assessment_path(assignment),
            class: "inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 " \
                   "text-sm font-medium text-white hover:bg-primary/90 transition-colors"
          ) { "#{self_cta_verb(assignment)} self-assessment" }
        else
          a(
            href: assessment_path(assignment),
            class: "inline-flex items-center gap-1.5 rounded-md border border-gray-300 " \
                   "dark:border-gray-600 px-3 py-1.5 text-sm font-medium " \
                   "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 " \
                   "transition-colors"
          ) { "View self-assessment" }
        end
      end
    end
  end

  # "Exploring PM3" on a report's card (ADR-22), linking into the lens.
  def exploration_chips(assignment)
    entries = @explorations.fetch(assignment.id, [])
    return if entries.empty?

    div(class: "mt-3") do
      render Views::Assessments::ExplorationChips.new(entries: entries, assessment_id: assignment.id)
    end
  end

  # Status block for a card. Reports show both parties (Self + Manager); a
  # person's own card shows self-status only (the manager's progress stays
  # private until alignment). Once alignment starts, a single phase chip
  # replaces the per-side chips.
  #
  # @param assignment [PersonFrameworkAssignment]
  # @param show_manager [Boolean]
  def status_badges(assignment, show_manager:)
    status = @card_statuses[[ assignment.framework_id, assignment.person_id ]]
    return render(Components::Kit::Badge.new("Not Started", variant: :default)) if status.nil?

    div(class: "flex flex-col items-end gap-1") do
      home_status_badges(status, show_manager: show_manager)
      # "Aligning · PM3" beside the home status (ADR-22): a conversation
      # about another role, linking into its lens.
      render Views::Assessments::LensAlignmentChips.new(alignments: status[:lens_alignments] || [],
                                                        assessment_id: assignment.id)
    end
  end

  def home_status_badges(status, show_manager:)
    case status[:status]
    when "aligning" then return render(Components::Kit::Badge.new("Aligning", variant: :warning))
    when "aligned"  then return render(Components::Kit::Badge.new("Aligned", variant: :success))
    end

    div(class: "flex flex-col items-end gap-1") do
      side_chip("Self", side_state(status[:self_complete], status[:self_human], status[:self_any]))
      if show_manager
        side_chip("Manager", side_state(status[:manager_complete], status[:manager_human], status[:manager_any]))
        if status[:self_complete] && status[:manager_complete]
          span(class: "text-xs text-gray-500 dark:text-gray-400") { "Ready to align" }
        end
      end
    end
  end

  # "Start" until the viewer has touched a rating this cycle — carried
  # (seeded) values don't count, so the verb agrees with the Self chip's
  # :not_started / :to_confirm work states.
  # @param assignment [PersonFrameworkAssignment]
  # @return [String]
  def self_cta_verb(assignment)
    status = @card_statuses[[ assignment.framework_id, assignment.person_id ]]
    return "Start" if status.nil?

    state = side_state(status[:self_complete], status[:self_human], status[:self_any])
    %i[not_started to_confirm].include?(state) ? "Start" : "Continue"
  end

  # Complete = every current-level cell vetted (human-owned) this cycle.
  # In progress = at least one human touch (rate / revise / confirm / clear).
  # To confirm = values exist but ALL are carried forward, untouched.
  # Not started = nothing at all.
  #
  # @return [Symbol] :complete | :in_progress | :to_confirm | :not_started
  def side_state(complete, human_touched, any_rated)
    return :complete if complete
    return :in_progress if human_touched
    return :to_confirm if any_rated

    :not_started
  end

  # One labelled side chip (e.g. "Self  In progress"). The :to_confirm state
  # bypasses Kit::Badge for the dashed-outline treatment — dashed is the
  # carried-forward signal everywhere (pills, level chips), so the list chip
  # rhymes with what the assessment page shows.
  def side_chip(label, state)
    variant, text = SIDE_STATES.fetch(state)
    div(class: "flex items-center gap-1.5") do
      span(class: "text-xs text-gray-500 dark:text-gray-400") { label }
      if variant == :to_confirm
        span(
          class: "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium " \
                 "border border-dashed border-amber-500 dark:border-amber-400 " \
                 "text-amber-800 dark:text-amber-300",
          title: "Carried from the previous cycle — open the assessment to confirm or change"
        ) { text }
      else
        render Components::Kit::Badge.new(text, variant: variant)
      end
    end
  end

  def empty_state
    div(class: "rounded-lg border-2 border-dashed border-gray-300 dark:border-gray-600 " \
               "p-12 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "You have not been assigned to any frameworks yet."
      end
    end
  end
end
