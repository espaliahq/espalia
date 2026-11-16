# frozen_string_literal: true

# A plan's Changes tab ([#287](https://github.com/espaliahq/espalia/issues/287)):
# what the Org Graph has learned since the base, where one scenario's planned
# changes stand against it, and what in that scenario no longer fits. It draws
# `team_planning_drift`, `team_planning_status` and `team_planning_attention`
# and decides none of their rules. Every change names its source of truth, the
# place someone goes to make it happen.
class Views::Plans::ChangesTab < Views::Base
  include Views::Plans::ScenarioTab

  FACTS = {
    "title" => "title", "level" => "level", "manager" => "manager", "cost_centre" => "cost centre",
    "site" => "site", "employment" => "employment"
  }.freeze
  STATUSES = {
    "done" => [ "Done", :success ], "pending" => [ "Pending", :neutral ],
    "conflicting" => [ "Conflicting", :danger ], "unknown" => [ "Unknown", :warning ], "plan_only" => [ "Plan only", :info ]
  }.freeze
  STAYING = "Staying"
  PLAN_ONLY = "Only in this plan"
  WHOLE_PLAN = "The whole plan"
  NARROW_NOTE = 100
  WIDE_NOTE = 320

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param drift [Hash] from `team_planning_drift`
  # @param status [Hash] from `team_planning_status`, for the scenario shown
  # @param attention [Hash] from `team_planning_attention`, for the same scenario
  # @param can_edit [Boolean] whether the viewer may note a change or settle a conflict
  # @param see_pay [Boolean] whether the viewer holds the see-pay right, without which a pay change takes no note from them
  def initialize(plan:, scenarios:, drift:, status:, attention:, can_edit: false, see_pay: false)
    @plan = plan
    @can_edit = can_edit
    @see_pay = see_pay
    @scenarios = scenarios
    @drift = drift
    @status = status
    @attention = attention
  end

  def view_template
    return unchecked(@drift) if @drift[:checked] == false

    div(class: "space-y-8") do
      drift_section
      planned_section
      attention_section
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def planned_subject(id) = @status[:names][id] || (id == plan_id ? WHOLE_PLAN : PLAN_ONLY)

  def scenario_id = @status[:scenario_id]

  def drift_section
    section(aria: { labelledby: "changes-drift-heading" }, data: { changes_section: "drift" }) do
      h3(id: "changes-drift-heading", class: "text-base font-semibold text-default") { "In the Org Graph since #{day(@plan[:base_on])}" }
      p(class: "mt-1 text-sm text-muted") { "What the Org Graph has learned since the plan's base, and the planned changes each one meets." }
      update_to_today if @can_edit && Date.iso8601(@plan[:base_on]) < Time.now.utc.to_date
      if @drift[:changes].empty?
        render Components::Kit::EmptyState.new(title: "Nothing has changed in the Org Graph since the base.", size: :panel)
      else
        ul(class: "mt-3 divide-y divide-default rounded-lg border border-default bg-default") do
          @drift[:changes].each { drift_row(it) }
        end
      end
    end
  end

  def update_to_today
    div(class: "mt-3") do
      render Components::Kit::Button.new(variant: :outline, size: :sm, href: rebase_plan_path(plan_id)) { "Update to today" }
    end
  end

  def drift_row(change)
    li(class: "flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:justify-between", data: { drift_change: change[:kind] }) do
      div(class: "min-w-0 space-y-1") do
        p(class: "text-sm text-default break-words") do
          span(class: ("line-through" if change[:withdrawn])) { describe(change) }
        end
        p(class: "text-xs text-muted") { drift_meta(change) }
        carried = carried_here(change[:meets])
        if carried.any?
          drift_settle(carried, change[:meets])
        elsif change[:meets].any?
          meets_line(change[:meets])
        end
      end
      div(class: "flex flex-wrap items-center gap-1.5 sm:justify-end") do
        render Components::Kit::Badge.new("From this plan", tone: :brand) if change[:from_plan]
        render Components::Kit::Badge.new("Withdrawn", tone: :warning) if change[:withdrawn]
        sources(change[:sources])
      end
    end
  end

  def drift_meta(change)
    learned = change[:learned_at] && Time.iso8601(change[:learned_at]).to_date
    takes = "Takes effect #{day(change[:effective_on])}"
    learned && learned.iso8601 != change[:effective_on] ? "#{takes} · learned #{day(learned)}" : takes
  end

  # The carried conflicts this change causes in the scenario on screen. A
  # conflict elsewhere is settled from its own scenario, so the buttons here
  # never act on a scenario the reader isn't looking at.
  def carried_here(meets)
    return [] unless @can_edit

    @status[:statuses].select do |entry|
      entry[:status].to_s == "conflicting" && entry[:since] && meets.any? do |met|
        met[:scenario_id] == entry[:scenario_id] && met[:subject_id] == entry[:subject_id] && met[:facet].to_s == entry[:facet].to_s
      end
    end
  end

  def drift_settle(carried, meets)
    div(class: "space-y-1", data: { drift_settle: scenario_id }) do
      p(class: "text-xs text-muted") { "Conflicts with the plan in #{scenario_name(scenario_id)}." }
      carried.each { settle(it) }
      others = meets.map { it[:scenario_id] }.uniq - [ scenario_id ]
      other_scenarios(others) if others.any?
    end
  end

  def other_scenarios(ids)
    p(class: "text-xs text-muted", data: { drift_settle_elsewhere: ids.size }) do
      plain "Also planned in #{ids.size} other #{"scenario".pluralize(ids.size)}, settled from #{ids.one? ? "its" : "each"} own tab: "
      ids.each_with_index do |id, index|
        plain ", " if index.positive?
        a(href: changes_plan_path(plan_id, scenario: scenario_param(id)), class: "text-link underline") { scenario_name(id) }
      end
    end
  end

  def meets_line(meets)
    p(class: "text-xs text-muted") do
      plain "Meets the plan in "
      meets.map { it[:scenario_id] }.uniq.each_with_index do |id, index|
        plain ", " if index.positive?
        a(href: changes_plan_path(plan_id, scenario: scenario_param(id)), class: "text-link underline") { scenario_name(id) }
      end
    end
  end

  def planned_section
    section(aria: { labelledby: "changes-planned-heading" }, data: { changes_section: "planned" }) do
      h3(id: "changes-planned-heading", class: "text-base font-semibold text-default") { "Planned in #{scenario_name(scenario_id)}" }
      p(class: "mt-1 text-sm text-muted") do
        "Where each planned change stands against the Org Graph today. A change the Org Graph never holds, such as a rule, reads Plan only."
      end
      scenario_picker(path: :changes_plan_path, select_id: "changes-scenario")
      if @status[:statuses].empty?
        render Components::Kit::EmptyState.new(title: "This scenario plans nothing yet.", size: :panel)
      else
        ul(class: "mt-3 divide-y divide-default rounded-lg border border-default bg-default") do
          @status[:statuses].each { planned_row(it) }
        end
      end
    end
  end

  # The Checks tab links an item's change here.
  #
  # @param change_id [String] the planned change's event id
  # @return [String] its row's id
  def self.change_anchor(change_id) = "change-#{change_id}"

  def planned_row(entry)
    li(id: self.class.change_anchor(entry[:change_id]), class: "flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:justify-between",
       data: { planned_change: entry[:status] }) do
      div(class: "min-w-0 space-y-1") do
        p(class: "text-sm text-default break-words") do
          strong(class: "font-medium") { planned_subject(entry[:subject_id]) }
          plain " · #{entry[:staying] ? STAYING : facet_name(entry[:facet])}"
        end
        planned_in(entry[:scenario_id]) if entry[:scenario_id] != scenario_id
        change_note(entry[:note])
        note_form(entry) if notable?(entry)
        settle(entry) if @can_edit && entry[:status].to_s == "conflicting"
      end
      div(class: "flex flex-wrap items-center gap-1.5 sm:justify-end") do
        status_badge(entry)
        sources(entry[:sources])
        clear(entry) if @can_edit && entry[:clearable]
      end
    end
  end

  # The read decides which rows may be cleared, so a pay change a member may
  # not touch never offers it. The dialog names the facet and never a value.
  def clear(entry)
    subject = planned_subject(entry[:subject_id])
    facet = entry[:staying] ? STAYING : facet_name(entry[:facet])
    render Components::Kit::Modal.new(id: "clear-#{entry[:change_id]}", title: "Clear #{subject}'s #{facet.downcase}?", size: :md) do |modal|
      render Components::Kit::Button.new(variant: :ghost, tone: :danger, size: :sm, compact: true, data: { action: "modal#open", clear_change: entry[:facet] },
                                         aria_label: "Clear #{subject} · #{facet}") { "Clear" }
      modal.body do
        p(class: "text-sm text-default") do
          "#{scenario_name(scenario_id)} will follow #{scenario_name(parent_of(scenario_id))} again here. " \
            "The change stays in the history, and Undo brings it back."
        end
        form(action: plan_clears_path(plan_id), method: "post", class: "mt-6 flex flex-wrap items-center gap-3") do
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          { scenario_id:, subject_id: entry[:subject_id], facet: entry[:facet], tab: "changes" }.each do |name, value|
            input(type: "hidden", name: name.to_s, value:)
          end
          render Components::Kit::Button.new(tone: :danger, type: :submit) { "Clear change" }
          render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
        end
      end
    end
  end

  def parent_of(id) = @scenarios.find { it[:scenario_id] == id }&.dig(:parent_id) || plan_id

  def planned_in(id)
    p(class: "text-xs text-muted", data: { planned_in: id }) do
      plain "Planned in "
      a(href: changes_plan_path(plan_id, scenario: scenario_param(id)), class: "text-link underline") { scenario_name(id) }
    end
  end

  # Only a conflict an update carried forward can be settled: before one, the
  # plan still reads the Org Graph as of its base, so keeping it changes nothing.
  def settle(entry)
    return update_first unless entry[:since]

    form(action: plan_settlements_path(plan_id), method: "post", class: "flex flex-wrap items-center gap-2 pt-1", data: { settle_conflict: entry[:facet] }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      { scenario_id:, subject_id: entry[:subject_id], facet: entry[:facet] }.each do |field, value|
        input(type: "hidden", name: "settlement[#{field}]", value:)
      end
      render Components::Kit::Button.new(type: :submit, size: :sm, compact: true, name: "settlement[choice]", value: "plan") { "Keep the plan" }
      if entry[:facet] == "succession"
        span(class: "text-xs text-muted") { "To follow reality, change the succession on the map." }
      else
        render Components::Kit::Button.new(type: :submit, variant: :outline, size: :sm, compact: true, name: "settlement[choice]", value: "reality") { "Follow reality" }
      end
    end
  end

  def update_first
    p(class: "text-xs text-muted", data: { settle_conflict: "live" }) do
      if Date.iso8601(@plan[:base_on]) < Time.now.utc.to_date
        a(href: rebase_plan_path(plan_id), class: "text-link underline") { "Update the plan to today" }
        plain " to keep the plan or follow reality here."
      else
        plain "The Org Graph changed today, so this can be settled after the next update to today."
      end
    end
  end

  # An erased note keeps its place, so the change doesn't read as never explained.
  # Its person was forgotten, so it takes no new one.
  def change_note(note)
    if note&.dig(:removed)
      p(class: "text-sm italic text-muted", data: { change_note: "removed" }) { "Note removed" }
    elsif note && (reach = clamp_reach(note[:value]))
      narrow = reach == :narrow
      div(class: "group/note space-y-1") do
        render Components::Kit::Prose.new(note[:value], class: [ "text-sm text-muted break-words line-clamp-3 group-has-[details[open]]/note:line-clamp-none", ("md:line-clamp-none" if narrow) ].compact.join(" "),
                                                        data: { change_note: "" })
        details(data: { change_note_more: "" }, class: [ "group/more text-xs", ("md:hidden" if narrow) ].compact.join(" ")) do
          summary(class: "inline-flex min-h-6 w-fit cursor-pointer list-none items-center rounded font-medium text-link hover:underline " \
                         "[&::-webkit-details-marker]:hidden") do
            span(class: "group-open/more:hidden") { "Show the whole note" }
            span(class: "hidden group-open/more:inline") { "Show less" }
          end
        end
      end
    elsif note
      render Components::Kit::Prose.new(note[:value], class: "text-sm text-muted break-words", data: { change_note: "" })
    end
  end

  # Where a note may run past the three lines a row shows: everywhere, only on
  # a row as narrow as a phone's, or nowhere. Lengths are a row's three lines
  # at each width, so a toggle never opens a note that already fits.
  def clamp_reach(text)
    if text.length > WIDE_NOTE || text.lines.count { it.strip.present? } > 3 then :everywhere
    elsif text.length > NARROW_NOTE then :narrow
    end
  end

  def notable?(entry)
    @can_edit && !entry.dig(:note, :removed) && Operations::TeamPlanning::ChangeNote.visible?(entry[:facet], see_pay: @see_pay)
  end

  # The note is written on the scenario that made the change, which for an
  # inherited one is not the scenario shown.
  def note_form(entry)
    id = "change-note-#{entry[:change_id]}"
    details(data: { change_note_editor: "" }, class: "text-sm") do
      summary(class: "inline-flex min-h-6 w-fit items-center rounded text-xs font-medium text-link hover:underline") { entry.dig(:note, :value) ? "Edit note" : "Add a note" }
      form(action: plan_note_path(plan_id, entry[:change_id]), method: "post", class: "mt-2 space-y-2") do
        input(type: "hidden", name: "_method", value: "patch")
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "note[scenario_id]", value: entry[:scenario_id])
        input(type: "hidden", name: "shown", value: scenario_param(scenario_id))
        label(for: id, class: "block text-sm font-medium text-default") { "Note" }
        textarea(id:, name: "note[text]", rows: "3", maxlength: TeamPlanning::PlanAggregate::NOTE_LIMIT,
                 aria: { describedby: "#{id}-hint" }, class: Components::Kit::Field::TEXTAREA) { entry.dig(:note, :value) }
        p(id: "#{id}-hint", class: "text-xs text-muted") { note_hint(entry) }
        render Components::Kit::Button.new(type: :submit, tone: :brand, size: :sm, compact: true) { "Save note" }
      end
    end
  end

  def note_hint(entry)
    hint = "#{Prose::COMPOSER_HINT}. Leave it blank to clear the note."
    return hint if entry[:scenario_id] == scenario_id

    "#{hint} It is saved on #{scenario_name(entry[:scenario_id])}, so every scenario that follows it shows it."
  end

  def status_badge(entry)
    label, tone = STATUSES.fetch(entry[:status])
    label = "#{label} since #{day(entry[:since])}" if entry[:since]
    render Components::Kit::Badge.new(label, tone:)
  end

  # The items themselves live on the Checks tab, grouped by check.
  def attention_section
    count = @attention[:items].size
    section(aria: { labelledby: "changes-attention-heading" }, data: { changes_section: "attention" }) do
      h3(id: "changes-attention-heading", class: "text-base font-semibold text-default") { "Needs attention" }
      if count.zero?
        render Components::Kit::EmptyState.new(title: "Everything in this scenario still fits.", size: :panel)
      else
        p(class: "mt-1 text-sm text-muted", data: { attention_count: count }) do
          plain "#{count} #{count == 1 ? 'item' : 'items'} in #{scenario_name(scenario_id)} no longer #{count == 1 ? 'fits' : 'fit'}. "
          render Components::Kit::Button.new(variant: :link, tone: :brand, compact: true,
                                             href: checks_plan_path(plan_id, scenario: scenario_param(scenario_id))) { "Review them in Checks" }
        end
      end
    end
  end

  def describe(change)
    person = name_of(change[:person_id])
    unit = unit_name(change[:unit_id])
    case change[:kind]
    when "joined" then "#{person} joined"
    when "left" then "#{person} left"
    when "fact_changed" then fact_line(person, change)
    when "membership_started" then "#{person} joined #{unit}"
    when "membership_ended" then "#{person} left #{unit}"
    when "membership_changed" then "#{person}'s place in #{unit} changed"
    when "moved" then "#{person} moved from #{unit_name(change[:from_unit_id])} to #{unit}"
    when "unit_created" then "#{unit} was created"
    when "unit_renamed" then "#{change.dig(:before, 'name') || unit} was renamed #{change.dig(:after, 'name') || unit}"
    when "unit_moved" then "#{unit} moved"
    when "unit_retired" then "#{unit} was retired"
    when "unit_succeeded" then "A succession was recorded"
    when "owner_added" then "#{person} became an owner of #{unit}"
    when "owner_removed" then "#{person} stopped owning #{unit}"
    else change[:kind].humanize
    end
  end

  def fact_line(person, change)
    fact = FACTS.fetch(change[:fact], change[:fact].to_s.humanize(capitalize: false))
    before = fact_value(change[:fact], change[:before])
    after = fact_value(change[:fact], change[:after])
    return "#{person}'s #{fact} changed" unless after

    before ? "#{person}'s #{fact} changed from #{before} to #{after}" : "#{person}'s #{fact} is now #{after}"
  end

  def fact_value(fact, fields)
    return unless fields.is_a?(Hash)
    return name_of(fields["manager_id"]) if fact == "manager" && fields["manager_id"]

    fields.values.select { it.is_a?(String) || it.is_a?(Numeric) }.join(", ").presence
  end

  def name_of(id) = id && @drift[:names].fetch(id, Person::FORMER_MEMBER)

  def unit_name(id) = id && @drift[:names].fetch(id, TeamPlanning::Attention::REMOVED_UNIT)

  def day(value)
    date = value.is_a?(Date) ? value : Date.iso8601(value)
    I18n.l(date, format: date.year == Date.current.year ? "%-d %b" : "%-d %b %Y")
  end
end
