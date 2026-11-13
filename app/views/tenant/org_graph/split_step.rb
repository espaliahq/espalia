# frozen_string_literal: true

# Splits a unit (#138) in three short pages: name the new units, place each
# member in one, then review who goes where, and who will be in no team,
# before applying it. Each page is a form that comes back here.
class Views::Tenant::OrgGraph::SplitStep < Views::Tenant::OrgGraph::UnitStep
  NAME_SLOTS = 3
  STAGES = %w[names place review].freeze

  # @param names [Array<String>] the new units' names so far
  # @param placements [Hash{String => String}] person id => the name of their new unit
  # @param stage [String, nil] one of {STAGES}; names until two are given
  def initialize(names: [], placements: {}, stage: nil, **)
    super(**)
    @names = names
    @placements = placements
    @stage = stage
  end

  private

  def title = "Split #{@unit.name}"

  def allowed? = @rights.split?

  def not_allowed_because
    if @unit.parent
      "The new units sit beside #{@unit.name}, under #{@unit.parent.name}, and you can't add units there."
    else
      "The new units sit at the top level, where only an admin or an Org Graph editor can add units."
    end
  end

  def body
    case stage
    when "names" then names_page
    when "place" then place_page
    else review_page
    end
  end

  def stage
    return "names" if names_problem || @stage.nil? || @stage == "names"

    STAGES.include?(@stage) ? @stage : "names"
  end

  def names_problem
    return if @stage.nil? || @stage == "names"
    return "Name at least two new units." if @names.size < 2

    "Give each new unit a different name." if @names.map(&:downcase).uniq.size < @names.size
  end

  # -- Name the new units ----------------------------------------------------

  def names_page
    if (problem = names_problem)
      render Components::Kit::Alert.new(tone: :danger, role: "alert", id: "org-unit-split-problem") { problem }
    end
    p(class: "text-sm text-default") do
      "Name the units that replace #{@unit.name}. They sit #{placement_phrase}, and #{@unit.name} retires."
    end
    step_form(new_tenant_org_unit_split_path(@unit), method: "get", class: "space-y-4") do
      carry_date
      input(type: "hidden", name: "stage", value: "place")
      NAME_SLOTS.times do |index|
        name_id = "org-unit-split-name-#{index}"
        div do
          label(for: name_id, class: "block text-sm font-medium text-default") do
            plain "#{%w[First Second Third][index]} new unit"
            span(class: "font-normal text-muted") { " (optional)" } if index >= 2
          end
          input(type: "text", id: name_id, name: "names[]", value: @names[index], required: index < 2,
                class: "#{Components::Kit::Field::INPUT} mt-1")
        end
      end
      submit("Next: place people")
    end
  end

  def placement_phrase
    level = @overview.level_of(@unit)&.name&.downcase
    where = @unit.parent ? "under #{@unit.parent.name}" : "at the top level"
    level ? "#{where} as #{level.pluralize}" : where
  end

  # -- Place each member -----------------------------------------------------

  def place_page
    if memberships.empty?
      p(class: "text-sm text-default") { "No one is in #{@unit.name}, so there is no one to place." }
    else
      p(class: "text-sm text-default") do
        "Choose a new unit for each person. Anyone you leave in no team stops being a member."
      end
    end
    step_form(new_tenant_org_unit_split_path(@unit), method: "get", class: "space-y-4") do
      carry_date
      carry_names
      input(type: "hidden", name: "stage", value: "review")
      ul(class: "divide-y divide-subtle", aria: { label: "Place the people in #{@unit.name}" }) do
        memberships.each { |membership| placement_row(membership) }
      end
      div(class: "flex flex-wrap items-center gap-3") do
        submit("Review the split")
        a(href: stage_path("names"), class: "text-sm text-link hover:underline") { "Change the names" }
      end
    end
  end

  def placement_row(membership)
    person = membership.person
    select_id = "org-unit-split-place-#{person.id}"
    li(class: "flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm") do
      label(for: select_id, class: "min-w-32 flex-1 font-medium text-default") { person.name }
      select(id: select_id, name: "placements[#{person.id}]", class: "#{Components::Kit::Field::SELECT} sm:w-56") do
        option(value: "", selected: !@names.include?(@placements[person.id])) { "No team" }
        @names.each { |name| option(value: name, selected: @placements[person.id] == name) { name } }
      end
    end
  end

  # -- Review and apply ------------------------------------------------------

  def review_page
    p(class: "text-sm text-default") { "#{@unit.name} retires, and its people go here:" }
    @names.each { |name| successor_summary(name) }
    unplaced_summary
    step_form(tenant_org_unit_split_path(@unit), class: "space-y-4") do
      carry_names
      @placements.each { |person_id, name| input(type: "hidden", name: "placements[#{person_id}]", value: name) }
      date_field
      div(class: "flex flex-wrap items-center gap-3") do
        submit("Split #{@unit.name}", tone: :danger)
        a(href: stage_path("place"), class: "text-sm text-link hover:underline") { "Change who goes where" }
      end
    end
  end

  def successor_summary(name)
    placed = memberships.select { |membership| @placements[membership.person.id] == name }
    section(class: "space-y-2", aria: { label: name }) do
      h3(class: "text-sm font-semibold text-default") do
        plain "#{name} "
        span(class: "font-normal text-muted") { "(#{people(placed.size)})" }
      end
      placed.any? ? people_list(placed, label: "Moving to #{name}") : p(class: "text-sm text-muted") { "No one yet." }
    end
  end

  def unplaced_summary
    unplaced = memberships.reject { |membership| @names.include?(@placements[membership.person.id]) }
    section(id: "org-unit-split-unplaced", class: "space-y-2", aria: { label: "Will be in no team" }) do
      h3(class: "text-sm font-semibold #{unplaced.any? ? 'text-warning' : 'text-default'}") do
        plain "Will be in no team "
        span(class: "font-normal text-muted") { "(#{people(unplaced.size)})" }
      end
      if unplaced.any?
        p(class: "text-sm text-muted") { "Their membership of #{@unit.name} ends." }
        people_list(unplaced, label: "Will be in no team")
      else
        p(class: "text-sm text-muted") { "Everyone has a new unit." }
      end
    end
  end

  # -- Shared ----------------------------------------------------------------

  def carry_date = input(type: "hidden", name: "on", value: @effective_on)

  def carry_names = @names.each { |name| input(type: "hidden", name: "names[]", value: name) }

  def stage_path(stage)
    new_tenant_org_unit_split_path(@unit, on: @effective_on, names: @names, placements: @placements, stage:)
  end
end
