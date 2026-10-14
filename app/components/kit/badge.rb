# frozen_string_literal: true

# Small label/tag for metadata display.
#
# @example
#   render Components::Kit::Badge.new("IC", variant: :info)
#   render Components::Kit::Badge.new("Must Have", variant: :primary)
#
class Components::Kit::Badge < Components::Base
  VARIANTS = {
    default: "bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300",
    primary: "bg-primary/10 text-primary-ink dark:bg-primary/20",
    success: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400",
    warning: "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400",
    info: "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"
  }.freeze

  BASE = "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"

  # The full class list for a variant — for a control that has to look like
  # a badge without being one (a `Kit::DefinitionTip` trigger).
  # @param variant [Symbol]
  # @return [String]
  def self.classes(variant) = "#{BASE} #{VARIANTS[variant]}"

  # @param label [String] the badge text
  # @param variant [Symbol] color variant
  def initialize(label, variant: :default)
    @label = label
    @variant = variant
  end

  def view_template
    span(class: self.class.classes(@variant)) { @label }
  end
end
