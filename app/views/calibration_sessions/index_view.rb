# frozen_string_literal: true

# Lists calibration sessions visible to the viewer — sessions they
# facilitate, or every session for admins — grouped by cycle, newest cycle
# first, live and draft sessions ahead of closed ones. Archived sessions are
# left out unless the viewer asks for them, and then sit in their own group
# at the bottom.
class Views::CalibrationSessions::IndexView < Views::Base
  include Views::Frameworks::Explorer::Concerns::KebabChrome

  STATUS_VARIANTS = { "draft" => :warning, "started" => :success, "closed" => :default }.freeze
  STATUS_LABELS = { "draft" => "Draft", "started" => "Live", "closed" => "Closed" }.freeze
  # Live first: it is the session someone is about to run.
  STATUS_ORDER = { "started" => 0, "draft" => 1, "closed" => 2 }.freeze

  # @param sessions [Array<CalibrationSession>] archived ones only when shown
  # @param cycles [Hash{String => AssessmentCycle}] keyed by cycle_id
  # @param member_counts [Hash{[String, String] => Integer}] keyed by [session_id, member_type]
  # @param outcome_counts [Hash{String => Integer}] keyed by session id (drafts absent)
  # @param people [Hash{String => Person}] archivers, by id
  # @param permissions [Hash{String => Hash}] session id → `{ rename:, archive:, restore: }`
  # @param archived_count [Integer] how many archived sessions the viewer can see
  # @param show_archived [Boolean]
  # @param can_define [Boolean]
  def initialize(sessions:, cycles:, member_counts:, can_define:, outcome_counts: {}, people: {},
                 permissions: {}, archived_count: 0, show_archived: false,
                 user: nil, current_tenant: nil, tenants: [])
    @sessions = sessions
    @cycles = cycles
    @member_counts = member_counts
    @outcome_counts = outcome_counts
    @people = people
    @permissions = permissions
    @archived_count = archived_count
    @show_archived = show_archived
    @can_define = can_define
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "w-full px-4 sm:px-6 py-8", data: { controller: "modal",
                                                    action: "keydown.esc@window->modal#escape" }) do
        page_header
        if @sessions.any?
          cycle_groups.each { |cycle_id, sessions| cycle_group(cycle_id, sessions) }
          archived_group if archived_sessions.any?
        else
          empty_state
        end
        render Views::CalibrationSessions::RenameSessionModal.new if any_renamable?
      end
    end
  end

  private

  # Not Kit::SectionHeading: its row doesn't wrap, and two actions beside the
  # title pushed the page sideways on a phone.
  def page_header
    div(class: "flex flex-wrap items-start justify-between gap-x-4 gap-y-3 mb-4") do
      div(class: "min-w-0") do
        h2(class: "text-xl font-bold text-gray-900 dark:text-white") { "Calibration" }
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
          "Run sessions with your managers to calibrate how they rate their reports"
        end
      end
      div(class: "flex flex-wrap items-center gap-2") do
        archived_toggle
        define_link if @can_define
      end
    end
  end

  def archived_toggle
    return unless @show_archived || @archived_count.positive?

    a(
      href: @show_archived ? calibration_sessions_path : calibration_sessions_path(archived: 1),
      class: "inline-flex items-center rounded-md px-3 py-2 text-sm font-medium whitespace-nowrap " \
             "text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800 " \
             "focus-visible:outline focus-visible:outline-2 focus-visible:outline-blue-700 " \
             "dark:focus-visible:outline-blue-300 transition-colors"
    ) { @show_archived ? "Hide archived" : "Show archived (#{@archived_count})" }
  end

  def define_link
    a(
      href: new_calibration_session_path,
      class: "inline-flex items-center rounded-md bg-primary px-3 py-2 whitespace-nowrap " \
             "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 " \
             "focus-visible:outline focus-visible:outline-2 " \
             "focus-visible:outline-offset-2 focus-visible:outline-primary transition-colors"
    ) { "Define calibration session" }
  end

  # [[cycle_id, sessions]] for the unarchived sessions, newest cycle first; a
  # session whose cycle row is gone sorts last.
  def cycle_groups
    @sessions.reject(&:archived?)
      .group_by(&:cycle_id)
      .sort_by { |cycle_id, _| -(@cycles[cycle_id]&.opened_at || Time.at(0)).to_f }
      .map { |cycle_id, sessions| [ cycle_id, sessions.sort_by { |s| [ STATUS_ORDER.fetch(s.status, 3), -s.created_at.to_f ] } ] }
  end

  def archived_sessions
    @archived_sessions ||= @sessions.select(&:archived?)
  end

  def cycle_group(cycle_id, sessions)
    cycle = @cycles[cycle_id]
    section(class: "mt-6", aria: { labelledby: "cycle-#{cycle_id}" }) do
      h2(id: "cycle-#{cycle_id}", class: "text-sm font-semibold text-gray-900 dark:text-white") do
        plain cycle&.name || "Cycle unavailable"
        if cycle
          span(class: "font-normal text-gray-600 dark:text-gray-300") { " · #{cycle.status}" }
        end
      end
      card_grid(sessions)
    end
  end

  def archived_group
    section(class: "mt-10", aria: { labelledby: "archived-sessions" }) do
      h2(id: "archived-sessions", class: "text-sm font-semibold text-gray-600 dark:text-gray-300") do
        plain "Archived"
        span(class: "font-normal") { " · #{archived_sessions.size}" }
      end
      card_grid(archived_sessions)
    end
  end

  def card_grid(sessions)
    div(class: "mt-3 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4") do
      sessions.each { |session| session_card(session) }
    end
  end

  # The name is the card's link, stretched over the card with `after:`, so
  # the kebab can sit inside the card without nesting a button in an `<a>`.
  def session_card(session)
    div(
      id: "calibration-session-card-#{session.id}",
      class: "relative rounded-lg border border-gray-200 dark:border-gray-700 " \
             "shadow-xs p-5 transition-colors hover:border-primary/60 " \
             "#{session.archived? ? 'bg-gray-50 dark:bg-gray-900' : 'bg-white dark:bg-gray-800'}"
    ) do
      div(class: "flex items-start justify-between gap-3") do
        div(class: "min-w-0 flex flex-wrap items-center gap-2") do
          h3(class: "min-w-0 break-words text-base font-semibold text-gray-900 dark:text-white") do
            a(href: calibration_session_path(session),
              class: "after:absolute after:inset-0 after:rounded-lg hover:text-primary-ink " \
                     "focus-visible:outline-hidden focus-visible:after:ring-2 focus-visible:after:ring-blue-700 " \
                     "dark:focus-visible:after:ring-blue-300") do
              session.name
            end
          end
          status_badge(session)
        end
        card_kebab(session)
      end
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { meta_line(session) }
      outcome_line(session)
      restore_button(session) if session.archived? && permission(session, :restore)
    end
  end

  def status_badge(session)
    if session.archived?
      render Components::Kit::Badge.new("Archived", variant: :default)
    else
      render Components::Kit::Badge.new(
        STATUS_LABELS.fetch(session.status, session.status),
        variant: STATUS_VARIANTS.fetch(session.status, :default)
      )
    end
  end

  # "Started 3 Oct · 4 raters · 23 calibrated"; an archived card says when
  # and by whom, and names its cycle (the group header no longer does).
  def meta_line(session)
    counts = "#{count_for(session, 'participant')} raters · #{count_for(session, 'calibrant')} calibrated"
    if session.archived?
      by = @people[session.archived_by_id]&.name
      [ "Archived #{short_date(session.archived_at)}#{" by #{by}" if by}",
        @cycles[session.cycle_id]&.name ].compact.join(" · ")
    elsif session.closed? && session.closed_at
      "Closed #{short_date(session.closed_at)} · #{counts}"
    elsif session.started? && session.started_at
      "Started #{short_date(session.started_at)} · #{counts}"
    else
      counts
    end
  end

  def outcome_line(session)
    count = @outcome_counts[session.id]
    return if count.nil?

    p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
      count == 1 ? "1 outcome" : "#{count} outcomes"
    end
  end

  # Above the stretched link so it stays clickable.
  def restore_button(session)
    form(action: unarchive_calibration_session_path(session), method: "post", class: "relative mt-3") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(type: "submit",
             class: "text-sm font-medium text-primary-ink hover:underline focus-visible:outline " \
                    "focus-visible:outline-2 focus-visible:outline-blue-700 " \
                    "dark:focus-visible:outline-blue-300 rounded-sm") { "Restore" }
    end
  end

  # Open · Rename… · Archive (closed) or Restore (archived). `relative` lifts
  # it above the card's stretched link; the menu is fixed so the grid's next
  # row can't paint over it.
  def card_kebab(session)
    div(class: "relative shrink-0 -mr-1") do
      render Components::Kit::Dropdown.new(align: :right, strategy: :fixed) do |dd|
        kebab_trigger(dd, label: "Actions for #{session.name}", reveal_classes: "opacity-100")
        dd.menu(width: "w-44") do
          a(href: calibration_session_path(session), role: "menuitem", class: kebab_item_classes) { "Open" }
          rename_item(session) if permission(session, :rename)
          if permission(session, :archive)
            menu_form_item(archive_calibration_session_path(session), "Archive")
          elsif permission(session, :restore)
            menu_form_item(unarchive_calibration_session_path(session), "Restore")
          end
        end
      end
    end
  end

  def rename_item(session)
    button(
      type: "button", role: "menuitem", class: kebab_item_classes,
      data: {
        action: "click->modal#open",
        modal_target_id: Views::CalibrationSessions::RenameSessionModal::ID,
        rename_session_action: name_calibration_session_path(session),
        rename_session_name: session.name
      }
    ) { "Rename…" }
  end

  def menu_form_item(action, label)
    form(action: action, method: "post", role: "none") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(type: "submit", role: "menuitem", class: kebab_item_classes) { label }
    end
  end

  def permission(session, key)
    @permissions.dig(session.id, key)
  end

  def any_renamable?
    @permissions.values.any? { |flags| flags[:rename] }
  end

  def short_date(time)
    time.year == Time.current.year ? time.strftime("%-d %b") : time.strftime("%-d %b %Y")
  end

  def count_for(session, member_type)
    @member_counts.fetch([ session.id, member_type ], 0)
  end

  def empty_state
    div(class: "text-center py-12") do
      p(class: "text-gray-600 dark:text-gray-300") do
        if @archived_count.positive?
          plain "Every session is archived. Show archived sessions to see them."
        else
          plain "No calibration sessions yet."
        end
      end
      if @can_define
        p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
          plain "Define one to compare how your managers rate their reports."
        end
      end
    end
  end
end
