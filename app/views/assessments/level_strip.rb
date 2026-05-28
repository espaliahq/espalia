# frozen_string_literal: true

# Horizontal strip of level chips for a single capability.
#
# Renders one LevelChip per merged level (primary perspective) and an
# optional thin sub-strip row for each secondary perspective with
# divergence markers.
#
class Views::Assessments::LevelStrip < Views::Base
  # @param cells [Hash<Integer, Hash>] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param capability_stable_id [String]
  # @param person_level [Integer]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param focused_ordinal [Integer, nil] currently focused level ordinal
  def initialize(cells:, merged_levels:, capability_stable_id:, person_level:,
                 context: :self, focused_ordinal: nil)
    @cells = cells
    @merged_levels = merged_levels
    @capability_stable_id = capability_stable_id
    @person_level = person_level
    @context = context
    @focused_ordinal = focused_ordinal
  end

  def view_template
    div(class: "space-y-1") do
      primary_strip
      level_labels
      secondary_sub_strips if secondary_perspectives.any?
    end
  end

  private

  def primary_strip
    div(class: "flex gap-1") do
      @merged_levels.each do |level|
        render Views::Assessments::LevelChip.new(
          cell_data: @cells[level[:ordinal]],
          capability_stable_id: @capability_stable_id,
          ordinal: level[:ordinal],
          person_level: @person_level,
          level_code: level[:level_code],
          context: @context,
          focused: level[:ordinal] == @focused_ordinal
        )
      end
    end
  end

  def level_labels
    div(class: "flex gap-1") do
      @merged_levels.each do |level|
        div(class: "flex-1 min-w-[60px] text-center") do
          span(class: "text-[10px] text-gray-400 dark:text-gray-500") do
            level[:level_code]
          end
        end
      end
    end
  end

  def secondary_sub_strips
    secondary_perspectives.each do |label, freq_key|
      has_any = @cells.any? { |_, c| c&.dig(freq_key).present? }
      next unless has_any

      div(class: "flex items-center gap-1 mt-0.5") do
        span(class: "text-[9px] text-gray-400 dark:text-gray-500 w-8 shrink-0") do
          "#{label}:"
        end
        div(class: "flex gap-0.5 flex-1") do
          @merged_levels.each do |level|
            cell = @cells[level[:ordinal]]
            freq = cell&.dig(freq_key)
            primary_freq = cell ? primary_frequency_for(cell) : nil
            diverges = freq.present? && primary_freq.present? && freq != primary_freq

            div(class: "flex-1 min-w-[60px] flex justify-center") do
              if freq.present?
                span(
                  class: "w-2 h-2 rounded-full #{dot_color(freq)} #{diverges ? 'ring-1 ring-amber-400' : ''}",
                  title: "#{label}: #{frequency_label(freq)}"
                ) { }
              else
                span(class: "w-2 h-2") { }
              end
            end
          end
        end
      end
    end
  end

  def secondary_perspectives
    case @context
    when :self
      [ [ "Mgr", :manager_frequency ], [ "Agreed", :aligned_frequency ] ]
    when :manager
      [ [ "Self", :current_frequency ], [ "Agreed", :aligned_frequency ] ]
    when :alignment
      [ [ "Self", :current_frequency ], [ "Mgr", :manager_frequency ] ]
    end.select { |_, key| @cells.any? { |_, c| c&.dig(key).present? } }
  end

  def primary_frequency_for(cell)
    case @context
    when :self      then cell[:current_frequency]
    when :manager   then cell[:manager_frequency]
    when :alignment then cell[:aligned_frequency]
    end
  end

  def dot_color(freq)
    case freq
    when "consistent" then "bg-green-400 dark:bg-green-500"
    when "occasional" then "bg-blue-300 dark:bg-blue-500"
    when "some"       then "bg-amber-300 dark:bg-amber-500"
    when "none"       then "bg-gray-300 dark:bg-gray-500"
    else "bg-gray-200 dark:bg-gray-600"
    end
  end

  def frequency_label(freq)
    { "consistent" => "Consistently", "occasional" => "Most times",
      "some" => "Some times", "none" => "None" }[freq] || freq
  end
end
