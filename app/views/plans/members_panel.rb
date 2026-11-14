# frozen_string_literal: true

# Who is in a plan (#226), by name and role.
class Views::Plans::MembersPanel < Views::Base
  # @param members [Array<Hash>] from `team_planning_plan_members`
  def initialize(members:)
    @members = members
  end

  def view_template
    render Components::Kit::Card.new(title: "Members", density: :compact) do |card|
      card.body do
        ul(class: "space-y-2 text-sm") do
          @members.each do |member|
            li(class: "flex items-center justify-between gap-3") do
              span(class: "min-w-0 break-words text-default") { member[:name] }
              span(class: "shrink-0 text-muted") { member[:role] == "editor" ? "Editor" : "Viewer" }
            end
          end
        end
      end
    end
  end
end
