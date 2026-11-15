# frozen_string_literal: true

# A plan's Changes tab ([#287](https://github.com/espaliahq/espalia/issues/287)):
# what the Org Graph has learned since the base, where one scenario's planned
# changes stand against it, and what in that scenario no longer fits. It draws
# `team_planning_drift`, `team_planning_status` and `team_planning_attention`
# and decides none of their rules. Every change names its source of truth, the
# place someone goes to make it happen.
class Views::Plans::ChangesTab < Views::Base
  FACETS = {
    "assignment" => "Placement", "level" => "Level", "reporting_line" => "Manager", "departure" => "Leaving",
    "unit" => "Unit", "succession" => "Succession", "position" => "Position"
  }.freeze
  FACTS = {
    "title" => "title", "level" => "level", "manager" => "manager", "cost_centre" => "cost centre",
    "site" => "site", "employment" => "employment"
  }.freeze
  STATUSES = {
    "done" => [ "Done", :success ], "pending" => [ "Pending", :neutral ],
    "conflicting" => [ "Conflicting", :danger ], "unknown" => [ "Unknown", :warning ]
  }.freeze
  PLAN_ONLY = "Only in this plan"
  REMOVED_UNIT = "A removed unit"

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param drift [Hash] from `team_planning_drift`
  # @param status [Hash] from `team_planning_status`, for the scenario shown
  # @param attention [Hash] from `team_planning_attention`, for the same scenario
  # @param can_edit [Boolean] whether the viewer may note a change
  def initialize(plan:, scenarios:, drift:, status:, attention:, can_edit: false)
    @plan = plan
    @can_edit = can_edit
    @scenarios = scenarios
    @drift = drift
    @status = status
    @attention = attention
  end

  def view_template
    div(class: "space-y-8") do
      drift_section
      planned_section
      attention_section
    end
  end

  private

  def plan_id = @plan[:plan_id]

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
        meets_line(change[:meets]) if change[:meets].any?
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
      p(class: "mt-1 text-sm text-muted") { "Where each planned change stands against the Org Graph today." }
      scenario_picker
      if @status[:statuses].empty?
        render Components::Kit::EmptyState.new(title: "This scenario plans nothing the Org Graph holds yet.", size: :panel)
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
          strong(class: "font-medium") { @status[:names][entry[:subject_id]] || PLAN_ONLY }
          plain " · #{FACETS.fetch(entry[:facet], entry[:facet].humanize)}"
        end
        p(class: "text-xs text-muted") { "Planned in #{scenario_name(entry[:scenario_id])}" } if entry[:scenario_id] != scenario_id
        change_note(entry[:note])
        note_form(entry) if @can_edit && !entry.dig(:note, :removed)
      end
      div(class: "flex flex-wrap items-center gap-1.5 sm:justify-end") do
        status_badge(entry)
        sources(entry[:sources])
      end
    end
  end

  # An erased note keeps its place, so the change doesn't read as never explained.
  # Its person was forgotten, so it takes no new one.
  def change_note(note)
    if note&.dig(:removed)
      p(class: "text-sm italic text-muted", data: { change_note: "removed" }) { "Note removed" }
    elsif note
      render Components::Kit::Prose.new(note[:value], class: "text-sm text-muted break-words", data: { change_note: "" })
    end
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

  def attention_section
    section(aria: { labelledby: "changes-attention-heading" }, data: { changes_section: "attention" }) do
      h3(id: "changes-attention-heading", class: "text-base font-semibold text-default") { "Needs attention" }
      p(class: "mt-1 text-sm text-muted") do
        "What no longer fits in #{scenario_name(scenario_id)}, such as someone placed who joined after the base or has left."
      end
      if @attention[:items].empty?
        render Components::Kit::EmptyState.new(title: "Everything in this scenario still fits.", size: :panel)
      else
        ul(class: "mt-3 divide-y divide-default rounded-lg border border-default bg-default") do
          @attention[:items].each { attention_row(it) }
        end
      end
    end
  end

  def attention_row(item)
    li(class: "flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:justify-between", data: { attention_item: item[:facet] }) do
      div(class: "min-w-0 space-y-1") do
        p(class: "text-sm text-default break-words") do
          facet = FACETS.fetch(item[:facet], item[:facet].humanize)
          if (name = attention_name(item[:subject_id]))
            strong(class: "font-medium") { name }
            plain " · #{facet}"
          else
            strong(class: "font-medium") { facet }
          end
        end
        p(class: "text-xs text-muted") { item[:reason] }
      end
      div(class: "flex flex-wrap items-center gap-1.5 sm:justify-end") { sources(item[:sources]) }
    end
  end

  # A pill per scenario on a wide screen; a phone picks from a list.
  def scenario_picker
    div(class: "mt-3 flex flex-wrap items-center gap-2") do
      nav(aria: { label: "Scenario" }, class: "hidden sm:flex flex-wrap items-center gap-2 text-sm") do
        span(class: "text-muted") { "Showing" }
        @scenarios.each { scenario_pill(it) }
      end
      form(action: changes_plan_path(plan_id), method: "get", class: "flex min-w-0 flex-1 items-center gap-2 text-sm sm:hidden",
           data: { controller: "auto-submit" }) do
        label(for: "changes-scenario", class: "text-muted") { "Showing" }
        select(id: "changes-scenario", name: "scenario", class: "min-w-0 flex-1 #{Components::Kit::Field::SELECT}",
               data: { action: "change->auto-submit#submit" }) do
          Views::Plans::ScenarioTable.tree(@scenarios).each do |scenario, depth|
            option(value: scenario_param(scenario[:scenario_id]).to_s, selected: scenario[:scenario_id] == scenario_id) { "#{'· ' * depth}#{scenario_name(scenario[:scenario_id])}" }
          end
        end
        noscript { render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Show" } }
      end
    end
  end

  def scenario_pill(scenario)
    current = scenario[:scenario_id] == scenario_id
    a(href: changes_plan_path(plan_id, scenario: scenario_param(scenario[:scenario_id])), aria: { current: ("page" if current) },
      class: "rounded-full border px-3 py-1 #{current ? 'border-brand bg-brand-subtle font-medium text-default' : 'border-default text-muted hover:text-default'}") do
      scenario_name(scenario[:scenario_id])
    end
  end

  def sources(providers)
    providers.each { render Components::Kit::Badge.new("Source: #{HrisConfig.provider_label(it)}", variant: :outline) }
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

  def unit_name(id) = id && @drift[:names].fetch(id, REMOVED_UNIT)

  # Attention leaves a unit the map no longer holds unnamed. It may still be the Org Graph's, so it isn't called plan-only.
  def attention_name(id) = @attention[:names][id] || @status[:names][id] || @drift[:names][id]

  def scenario_name(id)
    return "Today" if id == plan_id

    @scenarios.find { it[:scenario_id] == id }&.dig(:name) || "A removed scenario"
  end

  def scenario_param(id) = (id unless id == plan_id)

  def day(value)
    date = value.is_a?(Date) ? value : Date.iso8601(value)
    I18n.l(date, format: date.year == Date.current.year ? "%-d %b" : "%-d %b %Y")
  end
end
