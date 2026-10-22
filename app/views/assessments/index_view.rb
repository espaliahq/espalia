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
    render Components::Shell::PageLayout.new(
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
    div(class: "mb-6 flex flex-wrap items-start justify-between gap-x-6 gap-y-2") do
      div do
        h1(class: "text-2xl font-bold text-default") { "My Assessments" }
        p(class: "mt-1 text-sm text-muted") do
          "Self-assess your capabilities against your assigned framework."
        end
      end
      a(href: assessment_guide_path,
        class: "inline-flex min-h-11 items-center text-sm font-semibold text-link hover:text-link-hover hover:underline") do
        "How assessments work →"
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
      h2(id: "explorations-heading", class: "text-xl font-bold text-default mb-1") { "Explorations" }
      p(class: "text-sm text-muted mb-4") do
        "Roles and levels you're exploring. Your managers and admins can see them too."
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
        class: "block rounded-lg border border-lens bg-overlay p-4 " \
               "shadow-xs hover:border-lens-strong transition-colors " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-focus") do
        p(class: "font-semibold text-default break-words") { entry.label }
        p(class: "mt-1 text-sm text-muted") { exploration_meta(entry) }
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
      h2(class: "text-xl font-bold text-default mb-1") { "Team Assessments" }
      p(class: "text-sm text-muted mb-4") do
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
      h2(class: "text-xl font-bold text-default mb-1") { "Skip-Level Assessments" }
      p(class: "text-sm text-muted mb-4") do
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
      span(class: "text-xs text-muted tabular-nums") do
        "Showing #{pagy.from}–#{pagy.to} of #{pagy.count}"
      end
      div(class: "flex items-center gap-2") do
        skip_level_page_link("← Previous", pagy.previous)
        span(class: "text-xs text-muted tabular-nums") do
          "Page #{pagy.page} of #{pagy.last}"
        end
        skip_level_page_link("Next →", pagy.next)
      end
    end
  end

  # @param label [String]
  # @param page [Integer, nil] nil renders a disabled placeholder
  def skip_level_page_link(label, page)
    # Inactive, so exempt from 1.4.3 — but only if it says so: an `a` without an href
    # reads as ordinary text to axe and to a screen reader, hence the role.
    render Components::Kit::Button.new(
      variant: :outline, size: :xs, role: "link", disabled: page.nil?,
      href: assessments_path(skip_page: page || 1, anchor: "skip-level-assessments")
    ) { label }
  end

  def report_assignment_card(assignment)
    person = @report_people[assignment.person_id]
    cycle = @open_cycles[[ assignment.framework_id, assignment.person_id ]]

    render Components::Kit::Card.new do |card|
      card.body do
        div(class: "flex items-start justify-between") do
          div do
            h3(class: "text-lg font-semibold text-default") do
              person&.name || "Team Member"
            end
            p(class: "text-sm text-muted") do
              assignment.framework&.name || "Framework"
            end
            assignment_badges(assignment)
          end
          status_badges(assignment, show_manager: true)
        end

        if cycle&.name.present?
          p(class: "mt-3 text-sm text-muted") { cycle.name }
        end
        exploration_chips(assignment)

        div(class: "mt-4") do
          render Components::Kit::Button.new(variant: :outline, size: :sm, href: assessment_path(assignment)) do
            "Review assessment"
          end
        end
      end
    end
  end

  def assignment_card(assignment)
    cycle = @open_cycles[[ assignment.framework_id, assignment.person_id ]]

    render Components::Kit::Card.new do |card|
      card.body do
        div(class: "flex items-start justify-between") do
          div do
            h3(class: "text-lg font-semibold text-default") do
              assignment.framework&.name || "Framework"
            end
            assignment_badges(assignment)
          end
          status_badges(assignment, show_manager: false)
        end

        if cycle&.name.present?
          p(class: "mt-3 text-sm text-muted") { cycle.name }
        end

        div(class: "mt-4") do
          if cycle
            render Components::Kit::Button.new(tone: :brand, size: :sm, href: assessment_path(assignment)) do
              "#{self_cta_verb(assignment)} self-assessment"
            end
          else
            render Components::Kit::Button.new(variant: :outline, size: :sm, href: assessment_path(assignment)) do
              "View self-assessment"
            end
          end
        end
      end
    end
  end

  def assignment_badges(assignment)
    div(class: "mt-1 flex items-center gap-2") do
      render Components::Kit::Badge.new(assignment.role.name, variant: :info) if assignment.role
      render Components::Kit::Badge.new(assignment.level.title, variant: :default) if assignment.level
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
      side_chip("Manager", side_state(status[:manager_complete], status[:manager_human], status[:manager_any])) if show_manager
      ready_for_alignment_cue if ready_for_alignment?(status, show_manager: show_manager)
    end
  end

  # Nothing on the viewer's side stands between this card and alignment: the
  # person's own self-assessment is done, or on a report's card both sides are.
  def ready_for_alignment?(status, show_manager:)
    status[:self_complete] && (!show_manager || status[:manager_complete])
  end

  def ready_for_alignment_cue
    span(class: "text-xs text-muted") { Views::Assessments::StatusPill::READY_FOR_ALIGNMENT }
  end

  # "Start" until the viewer has touched a rating this cycle — carried
  # (seeded) values don't count, so the verb agrees with the Self chip's
  # :not_started / :to_confirm work states. "Review" while a finished
  # self-assessment waits for alignment, as on the home card.
  # @param assignment [PersonFrameworkAssignment]
  # @return [String]
  def self_cta_verb(assignment)
    status = @card_statuses[[ assignment.framework_id, assignment.person_id ]]
    return "Start" if status.nil?
    return "Review" if status[:self_complete] &&
                       AssessmentCycleProgress::INDIVIDUAL_RATING_STATUSES.include?(status[:status])

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
      span(class: "text-xs text-muted") { label }
      if variant == :to_confirm
        render Components::Shared::ToConfirmChip.new(
          text, title: "Carried from the previous cycle — open the assessment to confirm or change"
        )
      else
        render Components::Kit::Badge.new(text, variant: variant)
      end
    end
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "You have not been assigned to any frameworks yet.")
  end
end
