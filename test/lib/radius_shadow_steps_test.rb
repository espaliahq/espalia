# frozen_string_literal: true

require "test_helper"

# Each component owns one radius step from Tailwind's scale and one elevation role (#565, #597).
# Views are covered later, as each migrates onto Kit.
class RadiusShadowStepsTest < ActiveSupport::TestCase
  STEP = /(?<![\w-])(?:rounded|shadow)(?:-[a-z0-9]+)+/

  KIT_STEPS = {
    "alert.rb" => %w[rounded-md],
    "badge.rb" => %w[rounded-sm],
    "button.rb" => %w[rounded-md],
    "card.rb" => %w[rounded-2xl rounded-md shadow-raised],
    "chip.rb" => %w[rounded-full],
    "definition_tip.rb" => %w[rounded-md shadow-overlay],
    "description_list.rb" => %w[rounded-lg],
    "dropdown.rb" => %w[rounded-md shadow-overlay],
    "empty_state.rb" => %w[rounded-lg],
    "field.rb" => %w[rounded-md rounded-sm rounded-full],
    "modal.rb" => %w[rounded-lg rounded-md shadow-modal],
    "segmented_control.rb" => %w[rounded-full],
    "tag.rb" => %w[rounded-full],
    "toast.rb" => %w[shadow-overlay]
  }.freeze

  # Shell pieces that draw a surface of their own
  SHELL_SHADOWS = {
    "shell/impersonation_banner.rb" => %w[shadow-sm],
    "shell/navbar.rb" => %w[shadow-xs shadow-overlay],
    "shell/page_layout.rb" => %w[shadow-overlay]
  }.freeze

  should "keep every Kit component on the step it owns" do
    offenders = Dir[Rails.root.join("app/components/kit/*.rb")].flat_map do |path|
      allowed = KIT_STEPS.fetch(File.basename(path), [])
      steps_in(path).reject { |step, _| allowed.include?(step) }.map { |step, line| "#{relative(path)}:#{line} #{step}" }
    end

    assert_empty offenders, "Off-step radius or shadow in Kit (add it to KIT_STEPS only if the component owns it):\n#{offenders.join("\n")}"
  end

  should "leave shadows in Shared and Shell to the pieces that own a surface" do
    offenders = Dir[Rails.root.join("app/components/{shared,shell}/**/*.rb")].flat_map do |path|
      allowed = SHELL_SHADOWS.fetch(relative(path).delete_prefix("app/components/"), [])
      steps_in(path).select { |step, _| step.start_with?("shadow-") && !allowed.include?(step) }
                    .map { |step, line| "#{relative(path)}:#{line} #{step}" }
    end

    assert_empty offenders, "Shadow outside an owned surface; use the Kit component instead:\n#{offenders.join("\n")}"
  end

  private

  def steps_in(path)
    File.readlines(path).each_with_index.flat_map do |line, i|
      next [] if line.lstrip.start_with?("#")

      line.scan(STEP).map { |step| [ step, i + 1 ] }
    end
  end

  def relative(path)
    Pathname(path).relative_path_from(Rails.root).to_s
  end
end
