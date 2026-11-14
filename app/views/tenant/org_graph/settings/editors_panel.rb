# frozen_string_literal: true

# "Who may edit": the admins, the editors an admin chose with a way to add
# and remove them, and the narrower rights owners and managers hold.
class Views::Tenant::OrgGraph::Settings::EditorsPanel < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers

  # @param editors [Hash] as Operations::OrgGraph::Editors returns it
  # @param candidates [Array<Person>] members who could be made editors
  def initialize(editors:, candidates:)
    @editors = editors
    @candidates = candidates
  end

  def view_template
    render Components::Kit::Card.new(title: "Who may edit", heading_level: :h2, id: "org-graph-editors") do |card|
      card.body do
        dl(class: "space-y-4 text-sm") do
          group("Tenant admins", "Change anything, and choose the editors.") { names(@editors[:admins]) }
          group("Org Graph editors", "Change the sources, the units and anyone's facts.") { editor_list }
          group("Unit owners", "Change their unit and every unit beneath it.")
          group("Managers", "Move their reports between teams.")
        end
        add_form if @candidates.any?
      end
    end
  end

  private

  def group(term, detail)
    div do
      dt(class: "font-semibold text-default") { term }
      dd(class: "mt-0.5 text-muted") do
        plain detail
        yield if block_given?
      end
    end
  end

  def names(people)
    p(class: "mt-1 text-default") { people.map { it[:name] }.join(", ") } if people.any?
  end

  def editor_list
    if @editors[:editors].empty?
      p(class: "mt-1 text-default") { "None yet." }
      return
    end

    ul(class: "mt-1 divide-y divide-subtle") do
      @editors[:editors].each do |editor|
        li(class: "flex items-center justify-between gap-2 py-1.5") do
          span(class: "text-default min-w-0 truncate") { editor[:name] }
          next unless editor[:person_id]

          settings_form(tenant_org_graph_settings_editor_path(editor[:person_id]), method: :delete) do
            render Components::Kit::Button.new(variant: :ghost, tone: :danger, size: :sm, type: :submit,
                                               id: "remove-editor-#{editor[:person_id]}",
                                               aria_label: "Remove #{editor[:name]}") { "Remove" }
          end
        end
      end
    end
  end

  def add_form
    settings_form(tenant_org_graph_settings_editors_path, class: "mt-4 flex flex-col sm:flex-row gap-2") do
      label(for: "org-graph-new-editor", class: "sr-only") { "Person to make an editor" }
      select(id: "org-graph-new-editor", name: "person_id", class: "#{Components::Kit::Field::SELECT} sm:flex-1 min-w-0") do
        @candidates.each { |person| option(value: person.id) { person.name } }
      end
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit) { "Add an editor" }
    end
  end
end
