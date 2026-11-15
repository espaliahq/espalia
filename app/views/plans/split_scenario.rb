# frozen_string_literal: true

# Splitting the agreed part off a scenario
# ([#360](https://github.com/espaliahq/espalia/issues/360)): a box per change
# the scenario makes, what each can't go across without, and a name for the
# new part. It draws `team_planning_split_needs` and posts to
# `team_planning_split_scenario`, which decides every rule; a change names its
# subject and facet only, so pay reads as "Pay" and never as a value.
class Views::Plans::SplitScenario < Views::Base
  # @param plan [Hash] from `team_planning_plan`
  # @param scenario [Hash] from `team_planning_scenarios`, the one being split
  # @param needs [Hash] from `team_planning_split_needs`
  # @param draft [Hash] `{ event_ids:, name: }` from a refused split, to show again
  # @param error [String, nil] the split's refusal
  def initialize(plan:, scenario:, needs:, draft: {}, error: nil)
    @plan = plan
    @scenario = scenario
    @needs = needs
    @chosen = draft.fetch(:event_ids, []).to_set
    @name = draft[:name].presence || "#{scenario[:name]}, agreed part"
    @error = error
  end

  def view_template
    section(aria: { labelledby: "split-heading" }, class: "space-y-6", data: { split_scenario: @scenario[:scenario_id] }) do
      div do
        h3(id: "split-heading", class: "text-base font-semibold text-default break-words") { "Split #{@scenario[:name]}" }
        p(class: "mt-1 text-sm text-muted") do
          "A scenario is approved whole. When only part of it is agreed, split that part off so it can be approved " \
            "alone, and keep arguing the rest."
        end
      end
      render(Components::Kit::Alert.new(tone: :danger, role: "alert", title: "Couldn't split it")) { refusal } if @error
      changes.size < 2 ? nothing_to_split : choose
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def changes = @needs[:changes]

  def nothing_to_split
    p(class: "text-sm text-default") do
      if changes.empty?
        "#{@scenario[:name]} changes nothing yet, so there is nothing to split off."
      else
        "#{@scenario[:name]} makes one change, so there is nothing to split off. If it is agreed, approve it whole."
      end
    end
    render Components::Kit::Button.new(variant: :ghost, href: plan_path(plan_id)) { "Back to the scenarios" }
  end

  def choose
    form(action: split_plan_path(plan_id, scenario_id: @scenario[:scenario_id]), method: "post", class: "space-y-6") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      fieldset do
        legend(class: "text-sm font-semibold text-default") { "Choose what is agreed" }
        p(class: "mt-1 text-sm text-muted") do
          "Moving a change takes every earlier change to the same thing with it."
        end
        ul(class: "mt-2 divide-y divide-default rounded-lg border border-default bg-default") do
          changes.each { change_row(it) }
        end
      end
      name_field
      p(class: "text-sm text-muted") do
        "Nothing anyone sees changes. The agreed part takes #{@scenario[:name]}'s place, and the rest sits on it over " \
          "the same period, so every scenario reads exactly as before."
      end
      div(class: "flex flex-wrap items-center gap-2") do
        render(Components::Kit::Button.new(type: :submit, tone: :brand)) { "Split off the chosen changes" }
        render(Components::Kit::Button.new(variant: :ghost, href: plan_path(plan_id))) { "Cancel" }
      end
    end
  end

  def change_row(change)
    id = "split-change-#{change[:event_id]}"
    stuck = change[:needs].any? { it[:event_id].nil? }
    li(class: "flex gap-3 p-3", data: { split_change: change[:event_id] }) do
      input(type: "checkbox", id:, name: "event_ids[]", value: change[:event_id], checked: @chosen.include?(change[:event_id]),
            disabled: stuck, aria: { describedby: ("#{id}-needs" if change[:needs].any?) },
            class: "#{Components::Kit::Field::CHECKBOX} mt-0.5 shrink-0")
      div(class: "min-w-0 text-sm") do
        label(for: id, class: "block text-default break-words") { describe(change) }
        needs(change, "#{id}-needs", stuck) if change[:needs].any?
      end
    end
  end

  def needs(change, id, stuck)
    p(id:, class: "mt-0.5 text-muted break-words", data: { split_needs: change[:needs].size }) do
      strong(class: "font-medium text-danger") { stuck ? "Can't go across. " : "Can't go across alone. " }
      wanted = change[:needs].map { describe(it) }.to_sentence
      if stuck
        plain "It needs #{wanted}, and no change in this scenario makes that any more."
      else
        plain "It needs #{wanted}, so choose #{change[:needs].one? ? 'that change' : 'those changes'} too, or neither."
      end
    end
  end

  # The operation names what was left behind by id; the page knows each change's
  # needs, so it says the same in names and keeps the operation's words for
  # any other refusal.
  def refusal
    left_behind = changes.select { @chosen.include?(it[:event_id]) }.flat_map do |change|
      change[:needs].select { it[:event_id] && !@chosen.include?(it[:event_id]) }.map { [ describe(change), describe(it) ] }
    end
    return @error if left_behind.empty?

    left_behind.uniq.map { |moving, needed| "#{moving} needs #{needed}, which you left behind." }.join(" ") +
      " Choose #{left_behind.one? ? 'it' : 'them'} too, or leave out what needs #{left_behind.one? ? 'it' : 'them'}."
  end

  def name_field
    div do
      label(for: "split-name", class: "block text-sm font-semibold text-default") { "Name the agreed part" }
      p(id: "split-name-hint", class: "mt-1 text-sm text-muted") { "Say what was agreed, not who it is about." }
      input(type: "text", id: "split-name", name: "name", value: @name, required: true, aria: { describedby: "split-name-hint" },
            class: "#{Components::Kit::Field::INPUT} mt-2 max-w-md")
    end
  end

  def describe(change)
    "#{@needs[:names].fetch(change[:subject_id], Views::Plans::ChangesTab::PLAN_ONLY)}: #{facet_name(change[:facet])}"
  end

  def facet_name(facet)
    facets = Views::Plans::ChangesTab::FACETS
    facets.fetch(facet) { facets.fetch(facet.split(":").first, facet.humanize) }
  end
end
