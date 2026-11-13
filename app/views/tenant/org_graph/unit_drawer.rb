# frozen_string_literal: true

# The unit drawer (#124): a unit's name, level, parent, owners and members,
# with a form for each change the viewer may make. Every form posts on its
# own and comes back here; the date at the top applies to whichever is sent.
class Views::Tenant::OrgGraph::UnitDrawer < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Views::Tenant::OrgGraph::Formatting

  DATE_ID = "org-unit-effective-on"

  # @param unit [OrgUnit]
  # @param overview [OrgGraph::UnitsOverview] opened at the unit
  # @param rights [OrgGraphPolicy::UnitRights]
  # @param effective_on [String] ISO date the forms send
  # @param alert [String, nil] why the last change was refused
  def initialize(unit:, overview:, rights:, effective_on:, alert: nil)
    @unit = unit
    @overview = overview
    @rights = rights
    @effective_on = effective_on
    @alert = alert
  end

  def view_template
    render Views::Tenant::OrgGraph::Drawer.new(
      title: @unit.name,
      subtitle: subtitle,
      close_href: tenant_org_graph_path(unit: @unit.id)
    ) do
      div(class: "space-y-6", data: { controller: "effective-date", action: "submit->effective-date#stamp" }) do
        if @alert
          render Components::Kit::Alert.new(tone: :danger, role: "alert", id: "org-unit-alert") { @alert }
        end
        date_field
        details
        owners
        members
        reshape
      end
    end
  end

  private

  def subtitle
    level = @overview.level_of(@unit)&.name
    held = "from #{provider_label(@unit)}" unless @unit.held_by_espalia?
    [ level, held ].compact.join(", ").upcase_first.presence
  end

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

  # -- Name, level and parent ------------------------------------------------

  def details
    section(aria: { labelledby: "org-unit-details" }, class: "space-y-4") do
      h3(id: "org-unit-details", class: "text-sm font-semibold text-default") { "Details" }
      held_note unless @unit.held_by_espalia?
      @rights.rename? ? rename_form : fact("Name", @unit.name)
      fact("Level", @overview.level_of(@unit)&.name || "None")
      @rights.move? ? move_form : fact("Parent", parent_name)
    end
  end

  def held_note
    p(class: "flex items-center gap-1.5 text-sm text-muted") do
      icon(:lock, class: "size-4 shrink-0")
      plain "From #{provider_label(@unit)}: change its name and parent there."
    end
  end

  def fact(term, value)
    div do
      p(class: "text-xs text-muted") { term }
      p(class: "text-sm text-default") { value }
    end
  end

  def parent_name = @unit.parent&.name || "None (top level)"

  def rename_form
    drawer_form(tenant_org_unit_path(@unit), method: "patch", class: "space-y-1") do
      label(for: "org-unit-name", class: "block text-xs text-muted") { "Name" }
      div(class: "flex gap-2") do
        input(type: "text", id: "org-unit-name", name: "org_unit[name]", value: @unit.name, required: true,
              class: "#{Components::Kit::Field::INPUT} flex-1 min-w-0")
        submit("Rename")
      end
    end
  end

  def move_form
    drawer_form(tenant_org_unit_path(@unit), method: "patch", class: "space-y-1") do
      label(for: "org-unit-parent", class: "block text-xs text-muted") { "Parent" }
      div(class: "flex gap-2") do
        select(id: "org-unit-parent", name: "org_unit[parent_id]", class: "#{Components::Kit::Field::SELECT} flex-1 min-w-0") do
          option(value: "", selected: @unit.parent_id.nil?) { "None (top level)" } if @rights.root_choice?
          @rights.parent_choices.each { |unit| unit_option(unit, selected: unit.id == @unit.parent_id) }
        end
        submit("Move")
      end
    end
  end

  def unit_option(unit, selected: false)
    depth = @overview.path_to(unit).size - 1
    option(value: unit.id, selected:) { "#{" " * depth}#{unit.name}" }
  end

  # -- Owners ----------------------------------------------------------------

  def owners
    section(aria: { labelledby: "org-unit-owners" }, class: "space-y-3") do
      h3(id: "org-unit-owners", class: "text-sm font-semibold text-default") { "Owners" }
      own = @unit.own_owners.order(:name).to_a
      if own.any?
        ul(class: "divide-y divide-subtle", aria: { label: "Owners of #{@unit.name}" }) do
          own.each { |person| owner_row(person) }
        end
      else
        inherited_owners
      end
      add_owner_form if @rights.owners?
    end
  end

  def inherited_owners
    inherited = @unit.owners.order(:name).to_a
    text = if inherited.any?
      "None of its own. #{inherited.map(&:name).to_sentence} #{inherited.one? ? 'owns' : 'own'} it from above."
    else
      "No one owns this unit yet."
    end
    p(class: "text-sm text-muted") { text }
  end

  def owner_row(person)
    li(class: "flex items-center gap-3 py-2 text-sm") do
      span(class: "flex-1 min-w-0 font-medium text-default") { person.name }
      if @rights.owners?
        drawer_form(tenant_org_unit_owner_path(@unit, person.id), method: "delete") do
          submit("Remove", variant: :ghost, tone: :danger, aria_label: "Remove #{person.name} as an owner")
        end
      end
    end
  end

  def add_owner_form
    drawer_form(tenant_org_unit_owners_path(@unit), class: "space-y-2") do
      picker(field: "person_ids[]", frame: "owner-candidates", label: "Add an owner")
      submit("Add owner", variant: :outline)
    end
  end

  # -- Members ---------------------------------------------------------------

  def members
    memberships = @overview.members_of(@unit)
    section(aria: { labelledby: "org-unit-members" }, class: "space-y-3") do
      h3(id: "org-unit-members", class: "text-sm font-semibold text-default") do
        plain "Members "
        span(class: "font-normal text-muted") { "(#{memberships.size})" }
      end
      if memberships.empty?
        p(class: "text-sm text-muted") { "No one here directly." }
      else
        ul(class: "divide-y divide-subtle", aria: { label: "Members of #{@unit.name}" }) do
          memberships.each { |membership| member_row(membership) }
        end
      end
      add_member_form if @rights.add_members?
    end
  end

  def member_row(membership)
    person = membership.person
    li(id: "org-unit-member-#{person.id}", class: "space-y-2 py-3 text-sm") do
      div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-0.5") do
        span(class: "font-medium text-default") { person.name }
        span(class: "text-muted") { terms(membership) }
        unless membership.provider == ::OrgGraph::StructureAggregate::ESPALIA
          render Components::Kit::Badge.new("From #{HrisConfig.provider_label(membership.provider)}", leading_icon: :lock)
        end
      end
      member_actions(membership) if @rights.member?(membership)
    end
  end

  def terms(membership)
    allocation = "#{(membership.allocation * 100).round}%" if membership.allocation
    [ membership.role, allocation ].compact_blank.join(" · ")
  end

  def member_actions(membership)
    person = membership.person
    destinations = @rights.destinations(membership)
    div(class: "flex flex-wrap items-center gap-2") do
      if destinations.any?
        drawer_form(tenant_org_unit_member_path(@unit, person.id), method: "patch", class: "flex flex-1 gap-2 min-w-48") do
          select_id = "org-unit-move-#{person.id}"
          label(for: select_id, class: "sr-only") { "Move #{person.name} to" }
          select(id: select_id, name: "unit_id", required: true, class: "#{Components::Kit::Field::SELECT} flex-1 min-w-0") do
            option(value: "", disabled: true, selected: true) { "Move to…" }
            destinations.each { |unit| unit_option(unit) }
          end
          submit("Move", variant: :outline, aria_label: "Move #{person.name}")
        end
      end
      drawer_form(tenant_org_unit_member_path(@unit, person.id), method: "delete") do
        submit("Remove", variant: :ghost, tone: :danger, aria_label: "Remove #{person.name} from #{@unit.name}")
      end
    end
  end

  def add_member_form
    drawer_form(tenant_org_unit_members_path(@unit), class: "space-y-3") do
      picker(field: "person_ids[]", frame: "member-candidates", label: "Add people")
      div(class: "grid grid-cols-1 gap-3 sm:grid-cols-[1fr_8rem]") do
        div do
          label(for: "org-unit-role", class: "block text-xs text-muted") { "Role (optional)" }
          input(type: "text", id: "org-unit-role", name: "role", class: "#{Components::Kit::Field::INPUT} mt-1")
        end
        div do
          label(for: "org-unit-allocation", class: "block text-xs text-muted") { "Allocation %" }
          input(type: "number", id: "org-unit-allocation", name: "allocation", min: 1, max: 100, step: 1,
                inputmode: "numeric", placeholder: "100", class: "#{Components::Kit::Field::INPUT} mt-1")
        end
      end
      unless @unit.held_by_espalia?
        p(class: "text-xs text-muted") do
          "#{provider_label(@unit)} places the people it holds. Add here only people #{provider_label(@unit)} doesn't."
        end
      end
      submit("Add to #{@unit.name}", variant: :outline)
    end
  end

  # -- Retire, merge and split (#138) ---------------------------------------

  def reshape
    return unless !@unit.held_by_espalia? || @rights.reshape?

    section(aria: { labelledby: "org-unit-reshape" }, class: "space-y-3 border-t border-default pt-4") do
      h3(id: "org-unit-reshape", class: "text-sm font-semibold text-default") { "Split, merge or retire" }
      if !@unit.held_by_espalia?
        p(class: "flex items-center gap-1.5 text-sm text-muted") do
          icon(:lock, class: "size-4 shrink-0")
          plain "#{provider_label(@unit)} holds #{@unit.name}, so split, merge or retire it there."
        end
      elsif @rights.reshape?
        div(class: "flex flex-wrap gap-2") do
          reshape_link("Split", new_tenant_org_unit_split_path(@unit, on: @effective_on)) if @rights.split?
          reshape_link("Merge", new_tenant_org_unit_merge_path(@unit, on: @effective_on))
          reshape_link("Retire", new_tenant_org_unit_retirement_path(@unit, on: @effective_on), tone: :danger)
        end
      end
    end
  end

  def reshape_link(text, href, tone: :neutral)
    render Components::Kit::Button.new(variant: :outline, tone:, size: :sm, compact: true, href:,
                                       aria_label: "#{text} #{@unit.name}") { text }
  end

  # -- Shared ----------------------------------------------------------------

  def picker(field:, frame:, label:)
    render Views::Shared::PersonPicker.new(
      field_name: field,
      candidates_url: candidates_tenant_org_unit_path(@unit, frame:),
      frame_id: frame,
      label: label,
      placeholder: "Search people by name or email…"
    )
  end

  def drawer_form(action, method: "post", **attrs, &block)
    form(action:, method: "post", **attrs) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: method) unless method == "post"
      input(type: "hidden", name: "effective_on", value: @effective_on)
      block.call
    end
  end

  def submit(text, variant: :solid, tone: :brand, aria_label: nil)
    tone = :neutral if variant == :outline && tone == :brand
    render Components::Kit::Button.new(variant:, tone:, size: :sm, type: :submit, compact: true,
                                       aria_label:) { text }
  end
end
