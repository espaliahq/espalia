# frozen_string_literal: true

# What changed in the tenant's pay bands, exchange rates or budget lines,
# newest first, 25 to a page: each change with the row before and after, and
# who made it when.
class Views::Tenant::PlanningInputsHistories::ShowView < Views::Base
  include Views::Tenant::BudgetLines::LineText

  PAGES = {
    "pay_bands" => { title: "Pay band history", section: :pay_bands, back: "pay bands", path: :tenant_pay_bands_path },
    "exchange_rates" => { title: "Exchange rate history", section: :pay_bands, back: "pay bands",
                          path: :tenant_pay_bands_path },
    "budget_lines" => { title: "Budget history", section: :budget, back: "the budget", path: :tenant_budget_lines_path }
  }.freeze
  VERBS = { "added" => "Added", "changed" => "Changed", "removed" => "Removed" }.freeze

  # @param read [Hash] from `tenants_planning_inputs_history`
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(read:, user:, current_tenant:, tenants: [])
    @read = read
    @page = PAGES.fetch(read[:inputs])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: @page[:section], user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        @page[:title], tag: :h1, subtitle: "Every change, newest first, with who made it. Only tenant admins see this page."
      ) do |heading|
        heading.action do
          render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm, href: send(@page[:path])) do
            "Back to #{@page[:back]}"
          end
        end
      end
      @read[:changes].empty? ? empty : changes_card
    end
  end

  private

  def empty
    render Components::Kit::EmptyState.new(title: "No changes yet", size: :page) do
      plain "Each change made from now on is listed here."
    end
  end

  def changes_card
    render Components::Kit::Card.new(title: "Changes", heading_level: :h2, id: "planning-inputs-history") do |card|
      card.body do
        ol(class: "divide-y divide-default") { @read[:changes].each { change_row(it) } }
        pager
      end
    end
  end

  def change_row(change)
    li(class: "py-3 first:pt-0 last:pb-0", data: { history_change: change[:change] }) do
      p(class: "text-sm font-medium text-default break-words") { headline(change) }
      if change[:change] == "changed" && row_text(change[:before]) != row_text(change[:after])
        detail("Before", change[:before])
        detail("After", change[:after])
      elsif change[:change] == "changed"
        detail("Unchanged", change[:after])
      elsif change[:before] || change[:after]
        detail(nil, change[:after] || change[:before])
      end
      p(class: "text-xs text-muted") { byline(change) }
    end
  end

  def headline(change)
    row = change[:after] || change[:before]
    case change[:table]
    when "pay_band"
      change[:change] == "reordered" ? "Put the bands in a new order" : "#{VERBS.fetch(change[:change])} the band for #{band_name(row)}"
    when "exchange_rate" then "#{VERBS.fetch(change[:change])} the rate from #{row[:from_currency]} to #{row[:to_currency]}"
    when "reference_currency" then "Set the reference currency to #{row[:currency]}"
    when "budget_line" then "#{VERBS.fetch(change[:change])} the line for #{line_name(row)}"
    end
  end

  def detail(label, row)
    text = row_text(row) or return
    p(class: "text-sm text-default break-words") do
      span(class: "text-muted") { "#{label}: " } if label
      plain text
    end
  end

  def row_text(row)
    case @read[:inputs]
    when "pay_bands" then "#{range_text(row)} · #{midpoint_text(row)}"
    when "budget_lines" then "#{figures_text(row)} · #{terms_text(row)}"
    when "exchange_rates"
      row[:rate] && "1 #{row[:from_currency]} is #{row[:rate]} #{row[:to_currency]} from #{day_text(row[:applies_from])}"
    end
  end

  def byline(change)
    at = Time.zone.parse(change[:at]).in_time_zone(@current_tenant.working_zone).strftime("%-d %b %Y, %H:%M")
    by = change[:by] && "by #{change[:by]}"
    return [ "Recorded as it stood, last changed", by, "on #{at}" ].compact.join(" ") if change[:already_held]

    change[:by] ? "By #{change[:by]} on #{at}" : "On #{at}"
  end

  def pager
    page = @read[:page]
    return unless page > 1 || @read[:next_page]

    div(class: "mt-4 flex gap-4") do
      page_link("Newer", page - 1) if page > 1
      page_link("Older", page + 1) if @read[:next_page]
    end
  end

  def page_link(label, page)
    render Components::Kit::Button.new(variant: :link, tone: :brand, compact: true,
                                       href: tenant_planning_inputs_history_path(@read[:inputs], page:)) { label }
  end
end
