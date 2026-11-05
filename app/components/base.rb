# frozen_string_literal: true

class Components::Base < Phlex::HTML
  # Include any helpers you want to be available across all components
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::TurboFrameTag
  include Phlex::Rails::Helpers::TurboStreamFrom
  include Components::Helpers::LocalTimeHelpers
  include Components::Helpers::IconHelpers

  # The instance's product name (config.x.product_name, #660).
  # @return [String]
  def product_name = Rails.application.config.x.product_name

  if Rails.env.development?
    def before_template
      comment { "Before #{self.class.name}" }
      super
    end
  end
end
