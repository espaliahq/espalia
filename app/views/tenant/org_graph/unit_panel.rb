# frozen_string_literal: true

# The opened unit: its path, name and source, then a card for it and for
# each unit beneath it, listing the people directly in each.
class Views::Tenant::OrgGraph::UnitPanel < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Views::Tenant::OrgGraph::Formatting
  include Views::Tenant::OrgGraph::KeepsComparison

  # @param overview [OrgGraph::UnitsOverview] with a selected unit
  # @param comparison [OrgGraph::Comparison] marks what changed in the window
  # @param confirmations [OrgGraphPolicy::Confirmations, nil] stale flags for the members shown (#142)
  def initialize(overview:, comparison: OrgGraph::Comparison::NONE, confirmations: nil)
    @overview = overview
    @confirmations = confirmations
    @unit = overview.selected
    @comparison = comparison
  end

  def view_template
    section(aria: { labelledby: "org-graph-unit" }) do
      path = @overview.path_to(@unit)
      if path.size > 1
        p(class: "text-xs text-muted") { path[0..-2].map(&:name).join(" / ") }
      end
      div(class: "flex flex-wrap items-center gap-x-3 gap-y-1") do
        h3(id: "org-graph-unit", class: "text-lg font-semibold text-default") { @unit.name }
        @comparison.unit_marks(@unit).each { render Components::Kit::Badge.new(it, tone: :info) } unless own_card?
        unless @unit.held_by_espalia?
          render Components::Kit::Badge.new("From #{provider_label(@unit)}, read-only", leading_icon: :lock)
        end
        p(class: "text-sm text-muted") { unit_summary }
        render Components::Kit::Button.new(variant: :outline, size: :sm, href: edit_tenant_org_unit_path(@unit, **compared),
                                           class: "sm:ml-auto") do
          icon(:pencil, class: "size-4")
          plain "Edit unit"
        end
      end
      people_changes(@unit) unless own_card?

      div(class: "@container mt-4") do
        div(class: "grid grid-cols-1 @2xl:grid-cols-2 gap-4") do
          @overview.cards.each { |card_unit| unit_card(card_unit) }
        end
      end
    end
  end

  private

  # A unit with teams beneath it and no one directly in it has no card of its
  # own, so its marks and people changes show under its heading instead.
  def own_card? = @overview.cards.first&.id == @unit.id

  def unit_summary
    counts = @overview.descendants_of(@unit).map(&:level_id).tally
    beneath = @overview.levels.filter_map do |level|
      counts[level.id] && pluralize_level(counts[level.id], level.name)
    end
    [ people(@overview.headcount(@unit)), *beneath ].join(", ")
  end

  def unit_card(unit)
    render Components::Kit::Card.new(density: :compact, id: "unit-#{unit.id}") do |card|
      card.body do
        div(class: "flex items-baseline justify-between gap-3 pt-3") do
          div(class: "flex flex-wrap items-baseline gap-2") do
            h4(class: "font-semibold text-default") { unit.name }
            @comparison.unit_marks(unit).each { render Components::Kit::Badge.new(it, tone: :info) }
          end
          span(class: "shrink-0 text-sm text-muted tabular-nums") { card_count(unit) }
        end
        p(class: "text-xs text-muted") { @overview.level_of(unit)&.name }
        members_list(unit)
        people_changes(unit)
        sub_units_line(unit)
      end
    end
  end

  # The opened unit's own card sits beside its sub-units' cards, so it counts
  # only the people directly in it.
  def card_count(unit)
    if unit == @unit && @overview.children_of(unit).any?
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
      a(href: tenant_org_person_path(person, unit: @unit.id, **compared), class: "font-medium text-link hover:text-link-hover underline") { person.name }
      also = @overview.other_units_of(membership)
      span(class: "text-xs text-muted") { "also #{also.map(&:name).join(', ')}" } if also.any?
      span(class: "ml-auto flex items-baseline gap-3 text-muted") do
        span { [ membership.role, person.job_title ].compact_blank.join(" · ") }
        span(class: "tabular-nums") { "#{(membership.allocation * 100).round}%" } if membership.allocation
        hris_level(person)
      end
      stale_flag(membership) if @confirmations
    end
  end

  def stale_flag(membership)
    render Views::Tenant::OrgGraph::StaleFlag.membership(@confirmations, membership, back_to: { return_to: "units", unit: @unit.id, **@comparison.params })
  end

  def people_changes(unit)
    changes = @comparison.people_changes(unit)
    return if changes.empty?

    div(class: "mt-3 border-t border-subtle pt-2") do
      p(class: "text-xs font-semibold text-muted") { @comparison.window_label }
      ul(class: "mt-1 space-y-1 text-sm text-default", aria: { label: "#{@comparison.window_label} in #{unit.name}" }) do
        changes.each do |change|
          li do
            span(class: "font-medium text-default") { change.name }
            plain " #{change.text}"
          end
        end
      end
    end
  end

  def hris_level(person)
    return unless person.hris_level_ordinal

    render Components::Kit::Badge.new("L#{person.hris_level_ordinal}")
  end

  def sub_units_line(unit)
    return if unit == @unit

    children = @overview.children_of(unit)
    return if children.empty?

    p(class: "mt-3 text-sm text-muted") do
      plain "Beneath: "
      children.each_with_index do |child, index|
        plain ", " if index.positive?
        a(href: tenant_org_graph_path(unit: child.id, **compared), class: "text-link hover:text-link-hover underline") do
          "#{child.name} #{@overview.headcount(child)}"
        end
      end
    end
  end
end
