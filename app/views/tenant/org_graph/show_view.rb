# frozen_string_literal: true

# The Org Graph's Units view (#80): the unit tree beside the unit it opens,
# its sub-units as cards of members, and the people in no team below.
#
# Read-only. Opening a unit is a plain link with `?unit=`, so the view needs
# no script.
class Views::Tenant::OrgGraph::ShowView < Views::Base
  include Phlex::Rails::Helpers::Routes

  TRAY_ID = "in-no-team"

  # @param overview [OrgGraph::UnitsOverview]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(overview:, user:, current_tenant:, tenants: [])
    @overview = overview
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :org_graph,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Org Graph",
        subtitle: "Units and who is in each, as the Org Graph knows them today. Read-only for now."
      )

      if @overview.any_units?
        div(class: "mt-6 flex flex-col lg:flex-row gap-6") do
          unit_tree
          div(class: "flex-1 min-w-0 space-y-6") do
            selected_unit
            tray
          end
        end
      else
        div(class: "mt-6 space-y-6") do
          render Components::Kit::EmptyState.new(title: "No units yet") do
            "Units appear here once the Org Graph holds the organisation's structure."
          end
          tray
        end
      end
    end
  end

  private

  def unit_tree
    nav(
      class: "lg:w-64 lg:shrink-0 lg:self-start bg-default border border-default rounded-2xl p-3",
      aria: { labelledby: "org-graph-tree-label" }
    ) do
      p(id: "org-graph-tree-label", class: "px-2 pb-2 text-xs font-semibold uppercase tracking-wide text-muted") do
        @overview.levels.map(&:name).join(", ")
      end
      tree_list(@overview.roots)
      a(
        href: "##{TRAY_ID}",
        class: "mt-2 flex items-center justify-between rounded-md px-2 py-1.5 text-sm font-medium " \
               "text-warning hover:bg-default-hover"
      ) do
        span { "In no team" }
        span(class: "tabular-nums") { @overview.unplaced.size.to_s }
      end
    end
  end

  def tree_list(units)
    ul(class: "space-y-0.5") do
      units.each do |unit|
        li do
          tree_link(unit)
          children = @overview.children_of(unit)
          div(class: "pl-4") { tree_list(children) } if children.any?
        end
      end
    end
  end

  def tree_link(unit)
    selected = unit.id == @overview.selected&.id
    a(
      href: tenant_org_graph_path(unit: unit.id),
      class: [
        "flex items-center gap-1.5 rounded-md px-2 py-1.5 text-sm",
        selected ? "bg-neutral-muted font-semibold text-default" : "text-default hover:bg-default-hover"
      ],
      aria: { current: selected ? "page" : nil }
    ) do
      span(class: "min-w-0 truncate") { unit.name }
      hris_lock(unit) unless unit.held_by_espalia?
      span(class: "ml-auto pl-2 tabular-nums text-muted") { @overview.headcount(unit).to_s }
    end
  end

  def hris_lock(unit)
    icon(:lock, class: "size-3.5 shrink-0 text-muted")
    span(class: "sr-only") { "from #{provider_label(unit)}" }
  end

  def provider_label(unit) = HrisConfig.provider_label(unit.provider)

  def selected_unit
    unit = @overview.selected
    section(aria: { labelledby: "org-graph-unit" }) do
      path = @overview.path_to(unit)
      if path.size > 1
        p(class: "text-xs text-muted") { path[0..-2].map(&:name).join(" / ") }
      end
      div(class: "flex flex-wrap items-center gap-x-3 gap-y-1") do
        h3(id: "org-graph-unit", class: "text-lg font-semibold text-default") { unit.name }
        unless unit.held_by_espalia?
          render Components::Kit::Badge.new("From #{provider_label(unit)}, read-only", leading_icon: :lock)
        end
        p(class: "text-sm text-muted") { unit_summary(unit) }
      end

      div(class: "mt-4 grid grid-cols-1 xl:grid-cols-2 gap-4") do
        @overview.cards.each { |card_unit| unit_card(card_unit) }
      end
    end
  end

  def unit_summary(unit)
    beneath = @overview.descendants_of(unit).group_by { |child| @overview.level_of(child) }.filter_map do |level, units|
      level && pluralize_level(units.size, level.name)
    end
    [ people(@overview.headcount(unit)), *beneath ].join(", ")
  end

  def unit_card(unit)
    render Components::Kit::Card.new(density: :compact, id: "unit-#{unit.id}") do |card|
      card.body do
        div(class: "flex items-baseline justify-between gap-3 pt-3") do
          h4(class: "font-semibold text-default") { unit.name }
          span(class: "shrink-0 text-sm text-muted tabular-nums") { card_count(unit) }
        end
        p(class: "text-xs text-muted") { @overview.level_of(unit)&.name }
        members_list(unit)
        sub_units_line(unit)
      end
    end
  end

  # The opened unit's own card sits beside its sub-units' cards, so it counts
  # only the people directly in it.
  def card_count(unit)
    if unit == @overview.selected && @overview.children_of(unit).any?
      "#{@overview.members_of(unit).size} directly"
    else
      people(@overview.headcount(unit))
    end
  end

  def members_list(unit)
    members = @overview.members_of(unit)
    if members.empty?
      p(class: "mt-3 text-sm text-muted") { "No one here directly." }
      return
    end

    ul(class: "mt-3 divide-y divide-subtle", aria: { label: "Members of #{unit.name}" }) do
      members.each { |membership| member_row(membership) }
    end
  end

  def member_row(membership)
    person = membership.person
    li(class: "flex flex-wrap items-baseline gap-x-3 gap-y-0.5 py-2 text-sm") do
      span(class: "font-medium text-default") { person.name }
      also = @overview.other_units_of(membership)
      span(class: "text-xs text-muted") { "also #{also.map(&:name).join(', ')}" } if also.any?
      span(class: "ml-auto flex items-baseline gap-3 text-muted") do
        span { [ membership.role, person.job_title ].compact_blank.join(" · ") }
        span(class: "tabular-nums") { "#{(membership.allocation * 100).round}%" } if membership.allocation
        hris_level(person)
      end
    end
  end

  def hris_level(person)
    return unless person.hris_level_ordinal

    render Components::Kit::Badge.new("L#{person.hris_level_ordinal}")
  end

  def sub_units_line(unit)
    return if unit == @overview.selected

    children = @overview.children_of(unit)
    return if children.empty?

    p(class: "mt-3 text-sm text-muted") do
      plain "Beneath: "
      children.each_with_index do |child, index|
        plain ", " if index.positive?
        a(href: tenant_org_graph_path(unit: child.id), class: "text-link hover:text-link-hover underline") do
          "#{child.name} #{@overview.headcount(child)}"
        end
      end
    end
  end

  def tray
    people = @overview.unplaced
    render Components::Kit::Card.new(variant: :inset, density: :compact, edge: "border-warning", id: TRAY_ID,
                                     aria: { labelledby: "#{TRAY_ID}-heading" }) do |card|
      card.body do
        h3(id: "#{TRAY_ID}-heading", class: "pt-3 font-semibold text-warning") { "In no team, #{people.size}" }
        if people.empty?
          p(class: "mt-1 text-sm text-muted") { "Everyone active is in a team." }
        else
          p(class: "mt-1 text-sm text-muted") { "Active people the Org Graph holds in no live unit." }
          ul(class: "mt-3 flex flex-wrap gap-2") { people.each { |person| unplaced_person(person) } }
        end
      end
    end
  end

  def unplaced_person(person)
    li(class: "flex items-baseline gap-2 rounded-md border border-default bg-default px-3 py-1.5 text-sm") do
      span(class: "font-medium text-default") { person.name }
      details = [ person.job_title.presence, person.hris_level_ordinal && "L#{person.hris_level_ordinal}" ].compact
      span(class: "text-muted") { details.join(" ") } if details.any?
    end
  end

  def people(count) = "#{count} #{count == 1 ? 'person' : 'people'}"

  def pluralize_level(count, name)
    word = name.downcase
    "#{count} #{count == 1 ? word : word.pluralize}"
  end
end
