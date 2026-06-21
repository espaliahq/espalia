# frozen_string_literal: true

# User notification preferences — a type × channel matrix of toggles.
class Views::Settings::Notifications::ShowView < Views::Base
  include Phlex::Rails::Helpers::FormWith

  CHANNEL_LABELS = { in_app: "In-app", slack: "Slack", email: "Email" }.freeze

  # @param types [Array<NotificationType::Definition>]
  # @param channels [Array<Symbol>] channels to show as columns
  # @param enabled [Hash{Symbol => Hash{Symbol => Boolean}}] current effective state
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(types:, channels:, enabled:, user: nil, current_tenant: nil, tenants: [])
    @types = types
    @channels = channels
    @enabled = enabled
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-2xl mx-auto") do
        page_header
        preferences_form
      end
    end
  end

  private

  def page_header
    div(class: "mb-6") do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Notifications" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "Choose how you're notified. In-app always arrives instantly; other channels only ping you if you haven't seen the in-app notification within a few minutes."
      end
    end
  end

  def preferences_form
    form_with(url: settings_notifications_path, method: :patch, class: "space-y-6") do
      render Components::Kit::Card.new do |card|
        card.body { matrix_table }
      end
      div(class: "flex justify-end") do
        button(
          type: "submit",
          class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90"
        ) { "Save preferences" }
      end
    end
  end

  def matrix_table
    div(class: "divide-y divide-gray-100 dark:divide-gray-800") do
      header_row
      @types.each { |type| type_row(type) }
    end
  end

  def header_row
    div(class: "hidden sm:grid grid-cols-[1fr_repeat(var(--ch),5rem)] gap-4 pb-3 text-xs font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300",
        style: "--ch: #{@channels.size}") do
      span { "Notification" }
      @channels.each { |channel| span(class: "text-center") { CHANNEL_LABELS.fetch(channel, channel.to_s.humanize) } }
    end
  end

  def type_row(type)
    div(class: "grid grid-cols-1 sm:grid-cols-[1fr_repeat(var(--ch),5rem)] gap-x-4 gap-y-2 py-4 items-center",
        style: "--ch: #{@channels.size}") do
      div(class: "min-w-0") do
        span(class: "block text-sm font-medium text-gray-900 dark:text-white") { type.label }
        span(class: "block text-sm text-gray-600 dark:text-gray-300") { type.description }
      end
      @channels.each { |channel| channel_toggle(type, channel) }
    end
  end

  def channel_toggle(type, channel)
    name = "notification_preferences[#{type.key}][#{channel}]"
    field_id = "notif-#{type.key}-#{channel}"
    div(class: "flex sm:justify-center items-center gap-2") do
      # Mobile label (the column header is hidden < sm).
      label(for: field_id, class: "sm:hidden text-sm text-gray-700 dark:text-gray-200") do
        CHANNEL_LABELS.fetch(channel, channel.to_s.humanize)
      end
      input(type: "hidden", name: name, value: "0")
      input(
        type: "checkbox",
        name: name,
        id: field_id,
        value: "1",
        checked: @enabled.dig(type.key, channel),
        class: "h-5 w-5 rounded border-gray-300 text-primary focus-visible:ring-primary",
        aria: { label: "#{type.label}: #{CHANNEL_LABELS.fetch(channel, channel.to_s.humanize)}" }
      )
    end
  end
end
