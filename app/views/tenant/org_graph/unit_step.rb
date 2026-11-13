# frozen_string_literal: true

# What the unit drawer's retire, merge and split steps share (#138): the
# drawer chrome, a way back, and the reasons a unit can't be reshaped here.
# Each step says what will happen before the button that does it.
class Views::Tenant::OrgGraph::UnitStep < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Views::Tenant::OrgGraph::Formatting

  DATE_ID = "org-unit-step-effective-on"

  # @param unit [OrgUnit]
  # @param overview [OrgGraph::UnitsOverview] opened at the unit
  # @param rights [OrgGraphPolicy::UnitRights]
  # @param effective_on [String] ISO date the step opens with
  # @param alert [String, nil] why the last attempt was refused
  def initialize(unit:, overview:, rights:, effective_on:, alert: nil)
    @unit = unit
    @overview = overview
    @rights = rights
    @effective_on = effective_on
    @alert = alert
  end

  def view_template
    render Views::Tenant::OrgGraph::Drawer.new(title:, close_href: tenant_org_graph_path(unit: @unit.id)) do
      div(class: "space-y-6") do
        back_link
        render Components::Kit::Alert.new(tone: :danger, role: "alert", id: "org-unit-alert") { @alert } if @alert
        blocker = blocked_because
        blocker ? p(id: "org-unit-step-blocked", class: "text-sm text-default") { blocker } : body
      end
    end
  end

  private

  # @return [String] the drawer's title, e.g. "Retire Payments"
  def title = raise(NotImplementedError)

  def body = raise(NotImplementedError)

  # @return [Boolean] whether the viewer may take this step
  def allowed? = raise(NotImplementedError)

  def blocked_because
    if !@unit.held_by_espalia?
      "#{provider_label(@unit)} holds #{@unit.name}, so split, merge or retire it there."
    elsif children.any?
      "Move or retire #{@unit.name}'s sub-units first: #{children.map(&:name).to_sentence}."
    elsif !@rights.reshape?
      "You can't change #{@unit.name}'s shape. An admin, an Org Graph editor or an owner of the unit can."
    elsif !allowed?
      not_allowed_because
    end
  end

  # @return [String] why the viewer, who may reshape the unit, can't take this step
  def not_allowed_because = raise(NotImplementedError)

  def children = @overview.children_of(@unit)

  def memberships = @memberships ||= @overview.members_of(@unit).sort_by { |membership| membership.person.name }

  def back_link
    a(href: edit_tenant_org_unit_path(@unit, on: (@effective_on unless @effective_on == Date.current.iso8601)),
      class: "inline-block text-sm text-link hover:underline") { "Back to #{@unit.name}" }
  end

  # @param people [Array<OrgMembership>]
  # @param label [String] the list's accessible name
  def people_list(people, label:, id: nil)
    ul(id:, class: "divide-y divide-subtle rounded-md border border-default", aria: { label: }) do
      people.each do |membership|
        li(class: "flex flex-wrap items-baseline gap-x-3 px-3 py-2 text-sm") do
          span(class: "font-medium text-default") { membership.person.name }
          span(class: "text-muted") { membership.role } if membership.role.present?
        end
      end
    end
  end

  def date_field
    div do
      label(for: DATE_ID, class: "block text-sm font-medium text-default") { "Takes effect" }
      input(type: "date", id: DATE_ID, name: "effective_on", value: @effective_on, required: true,
            class: "#{Components::Kit::Field::INPUT} mt-1 sm:w-48")
    end
  end

  def step_form(action, method: "post", **attrs, &block)
    form(action:, method:, **attrs) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token) if method == "post"
      block.call
    end
  end

  def unit_option(unit, selected: false)
    depth = @overview.path_to(unit).size - 1
    option(value: unit.id, selected:) { "#{"\u2003" * depth}#{unit.name}" }
  end

  def submit(text, tone: :brand, variant: :solid)
    render Components::Kit::Button.new(variant:, tone:, type: :submit) { text }
  end
end
