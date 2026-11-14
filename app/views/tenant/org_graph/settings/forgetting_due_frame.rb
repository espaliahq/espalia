# frozen_string_literal: true

# How many leavers would be forgotten today, and the switch that turns the
# schedule on for exactly that many. It loads after the page, as the count
# asks the HRIS.
class Views::Tenant::OrgGraph::Settings::ForgettingDueFrame < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers

  FRAME_ID = "org-graph-forgetting-due"

  # @param count [Integer, nil] leavers due today
  # @param problem [String, nil] why they couldn't be counted
  # @param src [String, nil] the frame's own path, for the placeholder
  def initialize(count: nil, problem: nil, src: nil)
    @count = count
    @problem = problem
    @src = src
  end

  def view_template
    turbo_frame_tag(FRAME_ID, src: @src) do
      if @count
        due
      else
        p(class: "text-muted", role: ("status" if @problem), aria: { busy: @problem.nil?.to_s }) do
          @problem || "Counting who would be forgotten today…"
        end
      end
    end
  end

  private

  def due
    p(class: "text-default") do
      if @count.zero?
        "Nobody reaches their date today."
      else
        "#{@count} #{@count == 1 ? 'person reaches' : 'people reach'} their date today and would be forgotten on the next run."
      end
    end
    settings_form(tenant_org_graph_settings_forgetting_schedule_path, class: "mt-3", data: { turbo_frame: "_top" }) do
      input(type: "hidden", name: "confirm_count", value: @count)
      render Components::Kit::Button.new(variant: :outline, tone: :danger, type: :submit, id: "org-graph-forgetting-on") do
        "Turn on scheduled forgetting"
      end
    end
  end
end
