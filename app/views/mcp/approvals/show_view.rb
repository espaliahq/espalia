# frozen_string_literal: true

# Review page for an MCP in-app approval request. Shows the proposed
# operation, the originating client application, the arguments the MCP
# client submitted, and (after action) the outcome.
class Views::Mcp::Approvals::ShowView < Views::Base
  include Phlex::Rails::Helpers::Routes

  STATUS_TONES = { "pending" => :warning, "approved" => :success, "rejected" => :danger, "expired" => :neutral }.freeze

  # @param approval [Mcp::PendingApproval]
  def initialize(approval:)
    @approval = approval
  end

  def view_template
    div(class: "min-h-screen bg-page flex items-center justify-center p-4") do
      div(class: "w-full max-w-2xl space-y-6") do
        header
        details_card
        arguments_card
        result_card if @approval.executed_at
        action_buttons if @approval.resolvable?
      end
    end
  end

  private

  def header
    div(class: "text-center") do
      h1(class: "text-2xl font-bold text-default") { "MCP approval request" }
      p(class: "mt-1 text-sm text-muted") do
        plain "Review and confirm this action before #{@approval.client_application.name} runs it."
      end
    end
  end

  def details_card
    render Components::Kit::Card.new do |card|
      card.body do
        div(class: "space-y-3") do
          detail_row("Operation") { plain @approval.operation.description }
          detail_row("Tool name") { plain Operations::Registry.tool_name_for(@approval.operation) }
          detail_row("Requested by") { plain @approval.client_application.name }
          detail_row("Status") { status_pill }
          detail_row("Expires at") { plain @approval.expires_at.iso8601 }
          detail_row("Executed at") { plain @approval.executed_at.iso8601 } if @approval.executed_at
        end
      end
    end
  end

  def detail_row(label_text, &block)
    div(class: "flex items-baseline gap-4") do
      span(class: "text-xs uppercase tracking-wider text-muted w-32 shrink-0") { label_text }
      span(class: "text-sm text-default", &block)
    end
  end

  def status_pill
    render Components::Kit::Badge.new(@approval.status, tone: STATUS_TONES.fetch(@approval.status, :neutral))
  end

  def arguments_card
    render Components::Kit::Card.new(title: "Arguments", heading_level: :h2) do |card|
      card.body { json_block(@approval.arguments) }
    end
  end

  def result_card
    render Components::Kit::Card.new(title: "Result", heading_level: :h2) do |card|
      card.body { json_block(@approval.result_payload || {}) }
    end
  end

  def json_block(value)
    pre(class: "bg-muted rounded p-3 text-xs text-default overflow-x-auto") do
      plain JSON.pretty_generate(value)
    end
  end

  def action_buttons
    div(class: "flex gap-3") do
      form(action: approve_mcp_approval_path(@approval), method: :post, class: "flex-1") do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        render Components::Kit::Button.new(tone: :brand, touch: true, type: :submit, class: "w-full") { "Approve" }
      end
      form(action: reject_mcp_approval_path(@approval), method: :post, class: "flex-1") do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        render Components::Kit::Button.new(variant: :outline, touch: true, type: :submit, class: "w-full") { "Reject" }
      end
    end
  end
end
