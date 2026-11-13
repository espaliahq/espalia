# frozen_string_literal: true

# What an HRIS field would give, before an admin chooses it (#107): for a
# level, the units it would make and how many people fall in each; for a fact,
# how many people have a value and how many would change. It never says who is
# in a unit. The settings screen (6.9) loads it as a lazy frame.
class Views::Integrations::HrisFieldPreviewFrame < Views::Base
  FRAME_ID = "hris-field-preview"
  # A field holding a free-text value can give hundreds of units; the panel
  # names the largest and counts the rest.
  UNITS_SHOWN = 12
  TARGET_NAMES = { "level" => "level", "cost_centre" => "cost centre", "country" => "country" }.freeze

  # @param target [String] one of {Integrations::HrisFieldPreview::TARGETS}
  # @param preview [Hash, nil] the payload of {Operations::Integrations::HrisFieldPreview}
  # @param problem [String, nil] why the field could not be read
  # @param src [String, nil] the frame's own path, given only for the lazy placeholder
  def initialize(target:, preview: nil, problem: nil, src: nil)
    @target = target
    @preview = preview
    @problem = problem
    @src = src
  end

  def view_template
    turbo_frame_tag(FRAME_ID, src: @src, loading: ("lazy" if @src)) do
      if @preview
        summary
      else
        p(class: "text-sm text-muted", role: ("status" if @problem), aria: { busy: (@problem.nil?).to_s }) do
          @problem || "Reading the field from the HRIS…"
        end
      end
    end
  end

  private

  def summary
    div(class: "space-y-4") do
      h2(class: "text-base font-semibold text-default [overflow-wrap:anywhere]") do
        plain "#{@preview.dig(:field, :name)} as the #{TARGET_NAMES.fetch(@target, @target)}"
      end
      p(class: "text-sm text-muted") do
        plain "Read from the HRIS just now for #{people(@preview[:people])} Espalia holds. Nothing is saved."
      end
      level? ? units : fact_counts
    end
  end

  def level? = @preview[:target] == Integrations::HrisFieldPreview::LEVEL

  def units
    list = @preview[:units]
    counts("Units it would make" => list.size, **gaps)
    return if list.empty?

    ul(class: "divide-y divide-default rounded-md border border-default") do
      list.first(UNITS_SHOWN).each do |unit|
        li(class: "flex items-baseline justify-between gap-4 px-3 py-2 text-sm") do
          span(class: "text-default [overflow-wrap:anywhere]") { unit[:label] }
          span(class: "shrink-0 tabular-nums text-muted") { people(unit[:people]) }
        end
      end
    end
    return unless list.size > UNITS_SHOWN

    p(class: "text-sm text-muted") { "And #{list.size - UNITS_SHOWN} more units." }
  end

  def fact_counts
    counts("Have a value" => @preview[:with_value], "Would change" => @preview[:would_change], **gaps)
  end

  # Unreadable is rare, so it shows only when a record has one.
  def gaps
    { "Blank" => @preview[:blank], "Withheld by their record" => @preview[:withheld],
      "Unreadable" => (@preview[:unreadable] if @preview[:unreadable].to_i.positive?) }.compact
  end

  def counts(pairs)
    dl(class: "grid grid-cols-2 gap-3 sm:grid-cols-4") do
      pairs.each do |label, count|
        div(class: "rounded-md border border-default px-3 py-2") do
          dt(class: "text-xs text-muted") { label }
          dd(class: "mt-1 text-lg font-semibold tabular-nums text-default") { count.to_s }
        end
      end
    end
  end

  def people(count) = "#{count} #{count == 1 ? 'person' : 'people'}"
end
