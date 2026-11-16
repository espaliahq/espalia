# frozen_string_literal: true

# The tenant's time zone, shown beside the date it makes today, so an admin
# sees the effect before saving.
class Views::Tenant::TimeZone::EditView < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::FormWith

  DATE_FORMAT = "%A %-d %B %Y"

  # @param tenant [Tenant]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(tenant:, user:, current_tenant:, tenants: [])
    @tenant = tenant
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :time_zone, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Time zone",
        subtitle: "Where your organisation works. It decides what today is: the date a new plan starts " \
                  "from, and the date a change takes effect unless you pick another."
      )

      form_with(url: tenant_time_zone_path, method: :patch, scope: :tenant, class: "space-y-6") do |form|
        zone_card(form)
        actions(form)
      end
    end
  end

  private

  def zone_card(form)
    render Components::Kit::Card.new(title: "Your organisation's today") do |card|
      card.body do
        div(class: "flex flex-col gap-2 max-w-md", data: { controller: "zone-today" }) do
          label(for: "tenant_time_zone", class: "text-sm font-medium text-default") { "Time zone" }
          form.select(:time_zone, zone_options, { selected: @tenant.time_zone },
                      id: "tenant_time_zone", class: Components::Kit::Field::INPUT,
                      data: { zone_today_target: "zone", action: "zone-today#show" })
          p(class: "text-sm text-muted") do
            plain "Today there is "
            strong(data: { zone_today_target: "date" }) { @tenant.today.strftime(DATE_FORMAT) }
            plain "."
          end
        end

        p(class: "text-sm text-muted mt-4") do
          "Changing the zone moves today from the moment you save. It rewrites nothing: dates already " \
          "recorded keep their day, and times stay as they happened."
        end
      end
    end
  end

  def zone_options
    zones = ActiveSupport::TimeZone.all.group_by { it.tzinfo.name }
    [ [ "UTC", "UTC" ] ] + zones.except("Etc/UTC").map do |identifier, named|
      [ "(GMT#{named.first.formatted_offset}) #{named.map(&:name).join(', ')}", identifier ]
    end
  end

  def actions(form)
    div(class: "flex justify-end") do
      form.submit "Save", class: Components::Kit::Button.classes(tone: :brand, touch: true)
    end
  end
end
