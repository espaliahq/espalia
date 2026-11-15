# frozen_string_literal: true

# Which units a plan covers, as the new-plan form and the plan page's Covers
# dialog ask it ([#338](https://github.com/espaliahq/espalia/issues/338)).
# The unit list shows only once "Chosen units" is picked, through CSS alone.
class Views::Plans::ScopeFields < Views::Base
  # @param id [String] prefix for the fields' ids, unique on the page
  # @param units [Array<Hash>] from `team_planning_coverable_units`
  # @param chosen [Array<Hash>] `{ unit_id, name }` already covered; none means the whole organisation
  # @param hint [String] what the caller should know about changing it later
  # @param choosing [Boolean, nil] whether "Chosen units" is picked; when nil, whether any unit is chosen
  def initialize(id:, units:, hint:, chosen: [], choosing: nil)
    @choosing = choosing.nil? ? chosen.any? : choosing
    @id = id
    @units = units
    @chosen = chosen
    @hint = hint
  end

  def view_template
    fieldset(class: "group/scope", aria: { describedby: "#{@id}-hint" }) do
      legend(class: "block text-sm font-medium text-default") { "Covers" }
      div(class: "mt-1 flex flex-wrap gap-x-6 gap-y-2") do
        choice("whole", "The whole organisation", checked: !@choosing)
        choice("chosen", "Chosen units", checked: @choosing)
      end
      p(id: "#{@id}-hint", class: "mt-1 text-sm text-muted") { @hint }
      div(class: "mt-2 hidden group-has-[[value=chosen]:checked]/scope:block") { unit_list }
    end
  end

  private

  def choice(value, label, checked:)
    div(class: "flex items-center gap-2") do
      input(id: "#{@id}-#{value}", type: "radio", name: "plan[scope]", value:, checked:, class: Components::Kit::Field::RADIO)
      label(for: "#{@id}-#{value}", class: "text-sm text-default") { label }
    end
  end

  def unit_list
    if @units.empty? && gone.empty?
      p(class: "text-sm text-muted") { "Your organisation has no units yet, so a plan covers all of it." }
      return
    end

    ul(class: "max-h-64 overflow-y-auto rounded-md border border-default bg-field p-2 space-y-1", aria: { label: "Units" }) do
      @units.each { unit(it[:unit_id], it[:name], depth: it[:depth]) }
      gone.each { unit(it[:unit_id], "#{it[:name] || 'A former unit'} (no longer in the organisation)", depth: 0) }
    end
    p(class: "mt-1 text-sm text-muted") { "Each unit comes with everything under it." }
  end

  def unit(unit_id, name, depth:)
    field_id = "#{@id}-unit-#{unit_id}"
    li(class: "flex items-center gap-2", style: "padding-left: #{depth * 1.25}rem") do
      input(id: field_id, type: "checkbox", name: "plan[unit_ids][]", value: unit_id, checked: chosen_ids.include?(unit_id),
            class: Components::Kit::Field::CHECKBOX)
      label(for: field_id, class: "text-sm text-default break-words") { name }
    end
  end

  def chosen_ids = @chosen_ids ||= @chosen.to_set { it[:unit_id] }

  # Units the plan covers that the organisation has retired since: kept
  # checked, so widening never drops them unasked.
  def gone
    live = @units.to_set { it[:unit_id] }
    @chosen.reject { live.include?(it[:unit_id]) }
  end
end
