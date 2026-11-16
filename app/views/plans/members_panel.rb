# frozen_string_literal: true

# Who is in a plan (#226), by name and role, and who holds the see-pay right
# ([#300](https://github.com/espaliahq/espalia/issues/300)): who gave it and
# when, so a right a tenant admin restored stays visible to the holders.
class Views::Plans::MembersPanel < Views::Base
  include Phlex::Rails::Helpers::ButtonTo

  LINK = Components::Kit::Button.classes(variant: :link, tone: :brand, size: :sm, compact: true)
  DANGER_LINK = Components::Kit::Button.classes(variant: :link, tone: :danger, size: :sm, compact: true)

  # @param members [Array<Hash>] from `team_planning_plan_members`
  # @param plan_id [String, nil] needed only with `can_manage_see_pay`
  # @param can_manage_see_pay [Boolean] whether the viewer may grant and withdraw the right
  # @param reachable_ids [Array<String>] members still active and remembered, who alone can hold it
  # @param locked_out [Boolean] whether no reachable member holds the right, on a plan a tenant admin can restore
  def initialize(members:, plan_id: nil, can_manage_see_pay: false, reachable_ids: [], locked_out: false)
    @members = members
    @plan_id = plan_id
    @can_manage = can_manage_see_pay
    @reachable = reachable_ids.to_set
    @locked_out = locked_out
  end

  def view_template
    render Components::Kit::Card.new(title: "Members", density: :compact, heading_level: :h3) do |card|
      card.body do
        locked_out_notice if @locked_out
        ul(class: "space-y-3 text-sm") { @members.each { member(it) } }
      end
    end
  end

  private

  def locked_out_notice
    render Components::Kit::Alert.new(tone: :warning, size: :sm, class: "mb-3") do
      "No one in this plan can see pay. Ask a tenant admin to restore the right to its editors."
    end
  end

  def member(member)
    li(id: "plan-member-#{member[:person_id]}") do
      div(class: "flex items-center justify-between gap-3") do
        span(class: "min-w-0 break-words text-default") { member[:name] }
        span(class: "shrink-0 text-muted") { member[:role] == "editor" ? "Editor" : "Viewer" }
      end
      see_pay(member) if member[:see_pay]
      actions(member) if @can_manage
    end
  end

  def see_pay(member)
    granted = member[:see_pay_granted] || {}
    div(class: "mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted") do
      render Components::Kit::Badge.new("Sees pay", tone: :info)
      span { provenance(member[:person_id], granted) } if granted[:at]
    end
  end

  def provenance(person_id, granted)
    on = Time.iso8601(granted[:at]).to_date.strftime("%-d %B %Y")
    return "Restored by #{granted[:by_name]}, a tenant admin, on #{on}" if granted[:recovery]
    return "Since #{on}" if granted[:by_name].nil? || granted[:by_id] == person_id

    "Given by #{granted[:by_name]} on #{on}"
  end

  def actions(member)
    path = plan_see_pay_path(@plan_id, member[:person_id])
    if member[:see_pay]
      if holders > 1 || !@reachable.include?(member[:person_id])
        button_to("Withdraw pay access", path, method: :delete, class: DANGER_LINK,
                                               form: { class: "mt-1" }, aria: { label: "Withdraw pay access from #{member[:name]}" })
      end
    elsif @reachable.include?(member[:person_id])
      button_to("Give pay access", path, method: :patch, class: LINK,
                                         form: { class: "mt-1" }, aria: { label: "Give pay access to #{member[:name]}" })
    end
  end

  def holders = @holders ||= @members.count { it[:see_pay] && @reachable.include?(it[:person_id]) }
end
