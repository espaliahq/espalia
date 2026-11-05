# frozen_string_literal: true

class Components::Base < Phlex::HTML
  # Include any helpers you want to be available across all components
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::TurboFrameTag
  include Phlex::Rails::Helpers::TurboStreamFrom
  include Components::Helpers::LocalTimeHelpers
  include Components::Helpers::IconHelpers

  # What the platform is called here (#660): the current tenant's own name
  # for it, or the instance default.
  # @return [String]
  def product_name
    ActsAsTenant.current_tenant&.product_name || Rails.application.config.x.product_name
  end

  if Rails.env.development?
    def before_template
      comment { "Before #{self.class.name}" }
      super
    end
  end
end
