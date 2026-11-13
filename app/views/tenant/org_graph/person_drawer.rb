# frozen_string_literal: true

# The person drawer (#132): someone's teams, their employment facts and the
# history of both. Teams the viewer may change carry their own forms, which
# post on their own and come back here; the date at the top applies to
# whichever is sent. Employment is read-only: it changes where it is held.
class Views::Tenant::OrgGraph::PersonDrawer < Views::Base
  include Phlex::Rails::Helpers::Routes

  DATE_ID = "org-person-effective-on"
  ESPALIA = ::OrgGraph::StructureAggregate::ESPALIA

  # @param profile [OrgGraph::PersonProfile]
  # @param overview [OrgGraph::UnitsOverview] for unit depth in the choices
  # @param rights [OrgGraphPolicy::PersonRights]
  # @param effective_on [String] ISO date the forms send
  # @param unit_id [String, nil] the unit open behind the drawer
  # @param alert [String, nil] why the last change was refused
  def initialize(profile:, overview:, rights:, effective_on:, unit_id: nil, alert: nil)
    @profile = profile
    @person = profile.person
    @overview = overview
    @rights = rights
    @effective_on = effective_on
    @unit_id = unit_id
    @alert = alert
  end

  def view_template
    render Views::Tenant::OrgGraph::Drawer.new(
      title: @person.name, subtitle:, close_href: tenant_org_graph_path(unit: @unit_id)
    ) do
      div(class: "space-y-6", data: { controller: "effective-date", action: "submit->effective-date#stamp" }) do
        if @alert
          render Components::Kit::Alert.new(tone: :danger, role: "alert", id: "org-person-alert") { @alert }
        end
        date_field if editable?
        teams
        employment
        history
      end
    end
  end

  private

  def subtitle
    return "Forgotten. Their history stays; their name and details were erased." if @person.forgotten?

    facts = @profile.employment.index_by(&:fact)
    [ facts["title"]&.value, facts["employment"]&.value, facts["manager"]&.then { |f| "Reports to #{f.value}" } ]
      .compact.map { |part| "#{part}." }.join(" ").presence
  end

  def editable? = @rights.join? || @profile.memberships.any? { |membership| @rights.membership?(membership) }

  def date_field
    div do
      label(for: DATE_ID, class: "block text-sm font-medium text-default") { "Changes take effect" }
      p(id: "#{DATE_ID}-hint", class: "text-xs text-muted") { "Today unless you choose another day." }
      input(
        type: "date", id: DATE_ID, value: @effective_on, required: true,
        class: "#{Components::Kit::Field::INPUT} mt-1 sm:w-48",
        aria: { describedby: "#{DATE_ID}-hint" }, data: { effective_date_target: "date" }
      )
    end
  end

  # -- Teams -----------------------------------------------------------------

  def teams
    memberships = @profile.memberships
    section(aria: { labelledby: "org-person-teams" }, class: "space-y-3") do
      h3(id: "org-person-teams", class: "text-sm font-semibold text-default") { "Teams" }
      if memberships.empty?
        p(class: "text-sm text-muted") { "In no team." }
      else
        ul(class: "divide-y divide-subtle", aria: { label: "Teams of #{@person.name}" }) do
          memberships.each { |membership| team_row(membership) }
        end
      end
      join_form if @rights.join?
    end
  end

  def team_row(membership)
    unit = membership.unit
    li(id: "org-person-team-#{unit.id}", class: "space-y-2 py-3 text-sm") do
      div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-0.5") do
        span(class: "font-medium text-default") { unit.name }
        span(class: "text-muted") { terms(membership) }
        unless membership.provider == ESPALIA
          render Components::Kit::Badge.new("From #{HrisConfig.provider_label(membership.provider)}", leading_icon: :lock)
        end
      end
      p(class: "text-xs text-muted") { team_note(membership) }
      team_actions(membership) if @rights.membership?(membership)
    end
  end

  def terms(membership)
    allocation = "#{(membership.allocation * 100).round}%" if membership.allocation
    [ membership.role, allocation ].compact_blank.join(" · ")
  end

  def team_note(membership)
    since = "Since #{day(membership.member_since)}." if membership.member_since
    change = @profile.last_change_to(membership.unit_id)
    set_by = "Set by #{change.actor.name} on #{day(change.learned_at.to_date)}." if change&.actor
    held = "Change it in #{HrisConfig.provider_label(membership.provider)}." unless membership.provider == ESPALIA
    [ since, set_by, held ].compact.join(" ")
  end

  def team_actions(membership)
    unit = membership.unit
    destinations = @rights.destinations(membership)
    div(class: "flex flex-wrap items-center gap-2") do
      if destinations.any?
        drawer_form(tenant_org_person_membership_path(@person, unit.id), method: "patch", class: "flex flex-1 gap-2 min-w-48") do
          select_id = "org-person-move-#{unit.id}"
          label(for: select_id, class: "sr-only") { "Move from #{unit.name} to" }
          select(id: select_id, name: "unit_id", required: true, class: "#{Components::Kit::Field::SELECT} flex-1 min-w-0") do
            option(value: "", disabled: true, selected: true) { "Move to…" }
            destinations.each { |destination| unit_option(destination) }
          end
          submit("Move", variant: :outline, aria_label: "Move from #{unit.name}")
        end
      end
      drawer_form(tenant_org_person_membership_path(@person, unit.id), method: "delete") do
        submit("End", variant: :ghost, tone: :danger, aria_label: "End membership of #{unit.name}")
      end
    end
  end

  def join_form
    drawer_form(tenant_org_person_memberships_path(@person), class: "space-y-3") do
      div do
        label(for: "org-person-join", class: "block text-xs text-muted") { "Add to a team" }
        select(id: "org-person-join", name: "unit_id", required: true, class: "#{Components::Kit::Field::SELECT} mt-1 w-full") do
          option(value: "", disabled: true, selected: true) { "Choose a team…" }
          @rights.join_choices.each { |unit| unit_option(unit) }
        end
      end
      div(class: "grid grid-cols-1 gap-3 sm:grid-cols-[1fr_8rem]") do
        div do
          label(for: "org-person-role", class: "block text-xs text-muted") { "Role (optional)" }
          input(type: "text", id: "org-person-role", name: "role", class: "#{Components::Kit::Field::INPUT} mt-1")
        end
        div do
          label(for: "org-person-allocation", class: "block text-xs text-muted") { "Allocation %" }
          input(type: "number", id: "org-person-allocation", name: "allocation", min: 1, max: 100, step: 1,
                inputmode: "numeric", placeholder: "100", class: "#{Components::Kit::Field::INPUT} mt-1")
        end
      end
      submit("Add to team", variant: :outline)
    end
  end

  def unit_option(unit)
    depth = @overview.path_to(unit).size - 1
    option(value: unit.id) { "#{" " * depth}#{unit.name}" }
  end

  # -- Employment ------------------------------------------------------------

  def employment
    facts = @profile.employment
    section(aria: { labelledby: "org-person-employment" }, class: "space-y-3") do
      h3(id: "org-person-employment", class: "text-sm font-semibold text-default") { "Employment" }
      if facts.empty?
        p(class: "text-sm text-muted") { "No employment facts held." }
      else
        dl(class: "divide-y divide-subtle text-sm") do
          facts.each { |fact| employment_row(fact) }
        end
        p(class: "text-xs text-muted") { "Read-only here. Change each fact where it is held." }
      end
    end
  end

  def employment_row(fact)
    div(class: "grid grid-cols-[7rem_1fr] gap-x-3 py-2") do
      dt(class: "text-muted") { fact.label }
      dd(class: "min-w-0") do
        p(class: "text-default") { fact.value }
        p(class: "text-xs text-muted") { "#{HrisConfig.provider_label(fact.provider)}, since #{day(fact.since)}" }
      end
    end
  end

  # -- History ---------------------------------------------------------------

  def history
    changes = @profile.history
    section(aria: { labelledby: "org-person-history" }, class: "space-y-3") do
      h3(id: "org-person-history", class: "text-sm font-semibold text-default") { "History" }
      if changes.empty?
        p(class: "text-sm text-muted") { "Nothing recorded yet." }
      else
        ol(class: "divide-y divide-subtle text-sm", aria: { label: "History of #{@person.name}" }) do
          changes.each { |change| history_row(change) }
        end
        p(class: "text-xs text-muted") { "Each date is when the change took effect." }
      end
    end
  end

  def history_row(change)
    li(class: "grid grid-cols-[7rem_1fr] gap-x-3 py-2") do
      time(datetime: change.effective_on.iso8601, class: "text-muted") { day(change.effective_on) }
      div(class: "min-w-0") do
        p(class: "text-default") { change.summary }
        p(class: "text-xs text-muted") { origin(change) }
      end
    end
  end

  def origin(change)
    learned = "learned #{day(change.learned_at.to_date)}"
    by = change.actor ? "#{change.actor.name}, #{learned}" : learned.upcase_first
    "#{HrisConfig.provider_label(change.provider)}. #{by}"
  end

  # -- Shared ----------------------------------------------------------------

  def day(date) = date.strftime("%-d %b %Y")

  def drawer_form(action, method: "post", **attrs, &block)
    form(action:, method: "post", **attrs) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: method) unless method == "post"
      input(type: "hidden", name: "effective_on", value: @effective_on)
      input(type: "hidden", name: "unit", value: @unit_id) if @unit_id
      block.call
    end
  end

  def submit(text, variant: :solid, tone: :brand, aria_label: nil)
    tone = :neutral if variant == :outline && tone == :brand
    render Components::Kit::Button.new(variant:, tone:, size: :sm, type: :submit, compact: true,
                                       aria_label:) { text }
  end
end
