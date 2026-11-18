# frozen_string_literal: true

# The people switch and role menu the team card and team map share. The
# including view holds `@team`, the team operation's payload, and defines
# `team_path(**overrides)`, the link to itself with those choices changed.
module Views::Assessments::Concerns::TeamControls
  PEOPLE = { "direct" => [ "direct report", "direct reports" ], "below" => [ "person below you", "people below you" ] }.freeze
  RATINGS = { "manager" => "manager ratings", "self" => "self-ratings", "aligned" => "agreed ratings" }.freeze

  private

  # @return [Hash] the payload's choices, as the query string carries them
  def team_choices
    { team_people: (@team[:people] if @team[:people] != "direct"), team_role: @team.dig(:role, :id),
      team_level: @team[:level_ordinal], team_ratings: (@team[:ratings] if @team[:ratings] != "manager"),
      team_compare: ("none" if @team[:compare] == "none") }
  end

  def roles? = @team[:roles].size > 1

  # "10 direct reports", "1 person below you"
  def people_count(count = @team[:in_view])
    one, many = PEOPLE.fetch(@team[:people])
    "#{count} #{count == 1 ? one : many}"
  end

  def people_switch
    render Components::Kit::SegmentedControl.new(label: "Who is in the team") do |control|
      control.segment("Direct reports", selected: @team[:people] == "direct", href: team_path(team_people: nil),
                                        data: { refresh_focus: "people-direct" })
      control.segment("Everyone below you", selected: @team[:people] == "below", href: team_path(team_people: "below"),
                                            data: { refresh_focus: "people-below" })
    end
  end

  # One role at a time, since capabilities differ between roles.
  def role_menu
    div(data: { team_roles: true }) do
      render Components::Kit::Dropdown.new do |dropdown|
        dropdown.trigger(label: "Role shown: #{@team.dig(:role, :name)}", button: { variant: :outline, size: :sm }) do
          plain @team.dig(:role, :name)
          icon("chevron-down", class: "ml-1 size-4")
        end
        dropdown.menu(label: "Role shown") do
          @team[:roles].each do |role|
            dropdown.item(href: team_path(team_role: role[:id], team_level: nil),
                          aria: { current: ("true" if role[:id] == @team.dig(:role, :id)) }) do
              "#{role[:name]} · #{role[:people]}"
            end
          end
        end
      end
    end
  end
end
