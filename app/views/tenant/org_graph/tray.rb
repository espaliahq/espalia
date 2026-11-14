# frozen_string_literal: true

# The In no team tray: active people the Org Graph holds in no live unit.
class Views::Tenant::OrgGraph::Tray < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Views::Tenant::OrgGraph::KeepsComparison

  ID = "in-no-team"

  # @param people [Array<Person>]
  # @param unit_id [String, nil] the unit open beside the tray, which a person's drawer closes back to
  def initialize(people:, unit_id: nil)
    @people = people
    @unit_id = unit_id
  end

  def view_template
    anyone = @people.any?
    render Components::Kit::Card.new(variant: :inset, density: :compact, edge: ("border-warning" if anyone), id: ID,
                                     aria: { labelledby: "#{ID}-heading" }) do |card|
      card.body do
        h3(id: "#{ID}-heading", class: [ "pt-3 font-semibold", anyone ? "text-warning" : "text-default" ]) do
          "In no team, #{@people.size}"
        end
        if anyone
          p(class: "mt-1 text-sm text-muted") { "Active people the Org Graph holds in no live unit." }
          ul(class: "mt-3 flex flex-wrap gap-2") { @people.each { |person| unplaced_person(person) } }
        else
          p(class: "mt-1 text-sm text-muted") { "Everyone active is in a team." }
        end
      end
    end
  end

  private

  def unplaced_person(person)
    li(class: "flex items-baseline gap-2 rounded-md border border-default bg-default px-3 py-1.5 text-sm") do
      a(href: tenant_org_person_path(person, unit: @unit_id, **compared), class: "font-medium text-link hover:text-link-hover underline") { person.name }
      details = [ person.job_title.presence, person.hris_level_ordinal && "L#{person.hris_level_ordinal}" ].compact
      span(class: "text-muted") { details.join(" ") } if details.any?
    end
  end
end
