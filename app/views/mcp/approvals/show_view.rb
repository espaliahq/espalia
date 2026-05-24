# frozen_string_literal: true

# Review page for an MCP in-app approval request. Shows the proposed
# operation, the originating client application, the arguments the MCP
# client submitted, and (after action) the outcome.
class Views::Mcp::Approvals::ShowView < Views::Base
  include Phlex::Rails::Helpers::Routes

  # @param approval [Mcp::PendingApproval]
  def initialize(approval:)
    @approval = approval
  end

  def view_template
    div(class: "min-h-screen bg-gray-50 dark:bg-gray-950 flex items-center justify-center p-4") do
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
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "MCP approval request" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-400") do
        plain "Review and confirm this action before #{@approval.client_application.name} runs it."
      end
    end
  end

  def details_card
    div(class: "bg-white dark:bg-gray-900 rounded-2xl shadow p-6 space-y-3") do
      detail_row("Operation") { plain @approval.operation.description }
      detail_row("Tool name") { plain Operations::Registry.tool_name_for(@approval.operation) }
      detail_row("Requested by") { plain @approval.client_application.name }
      detail_row("Status") { status_pill }
      detail_row("Expires at") { plain @approval.expires_at.iso8601 }
      detail_row("Executed at") { plain @approval.executed_at.iso8601 } if @approval.executed_at
    end
  end

  def detail_row(label_text, &block)
    div(class: "flex items-baseline gap-4") do
      span(class: "text-xs uppercase tracking-wider text-gray-500 w-32 shrink-0") { label_text }
      span(class: "text-sm text-gray-900 dark:text-gray-100", &block)
    end
  end

  def status_pill
    classes = case @approval.status
    when "pending"  then "bg-amber-100 text-amber-800"
    when "approved" then "bg-green-100 text-green-800"
    when "rejected" then "bg-red-100 text-red-800"
    when "expired"  then "bg-gray-200 text-gray-700"
    end
    span(class: "inline-block rounded-full px-2 py-0.5 text-xs font-medium #{classes}") do
      plain @approval.status
    end
  end

  def arguments_card
    div(class: "bg-white dark:bg-gray-900 rounded-2xl shadow p-6") do
      h2(class: "text-sm font-semibold uppercase tracking-wider text-gray-500 mb-2") { "Arguments" }
      pre(class: "bg-gray-100 dark:bg-gray-800 rounded p-3 text-xs overflow-x-auto") do
        plain JSON.pretty_generate(@approval.arguments)
      end
    end
  end

  def result_card
    div(class: "bg-white dark:bg-gray-900 rounded-2xl shadow p-6") do
      h2(class: "text-sm font-semibold uppercase tracking-wider text-gray-500 mb-2") { "Result" }
      pre(class: "bg-gray-100 dark:bg-gray-800 rounded p-3 text-xs overflow-x-auto") do
        plain JSON.pretty_generate(@approval.result_payload || {})
      end
    end
  end

  def action_buttons
    div(class: "flex gap-3") do
      form(action: approve_mcp_approval_path(@approval), method: :post, class: "flex-1") do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        button(
          type: "submit",
          class: "w-full rounded-lg bg-primary px-4 py-2.5 text-sm font-semibold text-white hover:bg-secondary"
        ) { "Approve" }
      end
      form(action: reject_mcp_approval_path(@approval), method: :post, class: "flex-1") do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        button(
          type: "submit",
          class: "w-full rounded-lg border border-gray-300 bg-white px-4 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-50"
        ) { "Reject" }
      end
    end
  end
end
