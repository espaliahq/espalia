# frozen_string_literal: true

# The team card at the head of Team Assessments, drawn from
# `Operations::Assessments::TeamCapabilities`'s payload: the team's blades,
# how many capabilities it meets and its common gaps. Until two people in
# view have a score it is a blank slate, so a manager still learns it exists.
class Views::Assessments::TeamCard < Views::Base
  # People in view with a score before the team has a shape.
  MIN_SCORED = 2
  PEOPLE = { "direct" => %w[direct\ report direct\ reports], "below" => %w[person\ below\ you people\ below\ you] }.freeze
  RATINGS = { "manager" => "manager ratings", "self" => "self-ratings", "aligned" => "agreed ratings" }.freeze

  # @param team [Hash] `Operations::Assessments::TeamCapabilities`'s payload
  def initialize(team:)
    @team = team
  end

  def view_template
    render Components::Kit::Card.new(id: "team-card", data: { team_card: true }) do |card|
      card.body do
        div(class: "flex flex-col gap-4 sm:flex-row sm:items-center sm:gap-6") do
          shaped? ? blades : blank_disc
          div(class: "min-w-0 grow") do
            h3(class: "text-lg font-semibold text-default") { "Your team’s shape" }
            shaped? ? summary : blank_slate
          end
          controls
        end
      end
    end
  end

  private

  def shaped? = @team[:scored] >= MIN_SCORED

  def capabilities = @team[:capabilities]

  def blades
    render Views::Assessments::TeamBlades.new(
      capabilities:, size: "w-24 shrink-0 sm:w-28",
      label: "#{@team[:met]} of #{capabilities.size} capabilities met as a team"
    )
  end

  def blank_disc
    svg(viewBox: "-30 -30 60 60", class: "block aspect-square w-24 shrink-0 sm:w-28", aria: { hidden: "true" },
        data: { team_blank: true }) do |s|
      s.circle(r: 30, class: "fill-(--gos-surface-empty)")
      s.circle(r: 22, fill: "none", stroke_width: 0.9, stroke_dasharray: "2 2", class: "stroke-(--gos-content-muted)")
    end
  end

  def summary
    p(class: "mt-0.5 text-sm text-muted") { meta }
    p(class: "mt-3 text-sm text-default") do
      strong(class: "tabular-nums") { "#{@team[:met]} of #{capabilities.size}" }
      plain " capabilities met as a team."
      plain " Common gaps:" if @team[:gaps].any?
    end
    gaps if @team[:gaps].any?
  end

  def gaps
    ul(class: "mt-2 flex flex-wrap gap-2", aria: { label: "Common gaps" }) do
      @team[:gaps].each do |gap|
        li(data: { team_gap: gap[:stable_id] }) do
          render Components::Kit::Badge.new("#{gap[:name]} · #{gap[:short]} of #{gap[:scored]} short", variant: :warning)
        end
      end
    end
  end

  # "10 direct reports · Software Engineer · manager ratings"
  def meta
    one, many = PEOPLE.fetch(@team[:people])
    [ "#{@team[:in_view]} #{@team[:in_view] == 1 ? one : many}", @team.dig(:role, :name), RATINGS.fetch(@team[:ratings]) ].compact.join(" · ")
  end

  def controls
    return unless @team[:indirect_reports] || roles?

    div(class: "flex shrink-0 flex-col items-start gap-3 sm:items-end") do
      people_switch if @team[:indirect_reports]
      role_menu if roles?
    end
  end

  def roles? = @team[:roles].size > 1

  # One role at a time, since capabilities differ between roles.
  def role_menu
    div(data: { team_roles: true }) do
      render Components::Kit::Dropdown.new do |dropdown|
        dropdown.trigger(label: "Role shown", button: { variant: :outline, size: :sm }) do
          plain @team.dig(:role, :name)
          icon("chevron-down", class: "ml-1 size-4")
        end
        dropdown.menu(label: "Role shown") do
          @team[:roles].each do |role|
            dropdown.item(href: team_path(team_role: role[:id]), aria: { current: ("true" if role[:id] == @team.dig(:role, :id)) }) do
              "#{role[:name]} · #{role[:people]}"
            end
          end
        end
      end
    end
  end

  def people_switch
    render Components::Kit::SegmentedControl.new(label: "Who is in the team") do |control|
      control.segment("Direct reports", selected: @team[:people] == "direct", href: team_path(team_people: nil))
      control.segment("Everyone below you", selected: @team[:people] == "below", href: team_path(team_people: "below"))
    end
  end

  # The page with the team card's choices, `overrides` replacing them.
  def team_path(**overrides)
    assessments_path({ team_people: (@team[:people] if @team[:people] != "direct"),
                       team_role: (@team.dig(:role, :id) if roles?) }.merge(overrides).compact,
                     anchor: "team-card")
  end

  def blank_slate
    p(class: "mt-1 text-sm text-muted") do
      plain "Shows once at least two of your reports have a score. "
      strong(class: "text-default tabular-nums") { "#{@team[:scored]} of #{@team[:in_view]}" }
      plain " #{@team[:scored] == 1 ? 'has' : 'have'} one so far."
    end
    p(class: "mt-2 text-sm text-muted") do
      "A report gets a score once enough of their capabilities are rated, the same point their assessment shows its score."
    end
  end
end
