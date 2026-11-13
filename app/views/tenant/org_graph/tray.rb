# frozen_string_literal: true

# The In no team tray: active people the Org Graph holds in no live unit.
class Views::Tenant::OrgGraph::Tray < Views::Base
  ID = "in-no-team"

  # @param people [Array<Person>]
  def initialize(people:)
    @people = people
  end

  def view_template
    render Components::Kit::Card.new(variant: :inset, density: :compact, edge: "border-warning", id: ID,
                                     aria: { labelledby: "#{ID}-heading" }) do |card|
      card.body do
        h3(id: "#{ID}-heading", class: "pt-3 font-semibold text-warning") { "In no team, #{@people.size}" }
        if @people.empty?
          p(class: "mt-1 text-sm text-muted") { "Everyone active is in a team." }
        else
          p(class: "mt-1 text-sm text-muted") { "Active people the Org Graph holds in no live unit." }
          ul(class: "mt-3 flex flex-wrap gap-2") { @people.each { |person| unplaced_person(person) } }
        end
      end
    end
  end

  private

  def unplaced_person(person)
    li(class: "flex items-baseline gap-2 rounded-md border border-default bg-default px-3 py-1.5 text-sm") do
      span(class: "font-medium text-default") { person.name }
      details = [ person.job_title.presence, person.hris_level_ordinal && "L#{person.hris_level_ordinal}" ].compact
      span(class: "text-muted") { details.join(" ") } if details.any?
    end
  end
end
