# frozen_string_literal: true

# Tabbed assessment capability matrix.
# Renders a category tab bar above the matrix table, showing one category at a time.
# Passes context and all scoring perspectives through to AssessmentCategoryGroup children.
#
# The tab bar is rendered outside the horizontally-scrollable table wrapper so it
# remains fixed at the top when the user scrolls the matrix left/right.
#
class Views::Assessments::AssessmentMatrix < Views::Base
  # @param matrix_data [Hash] from Assessments::MatrixDataBuilder
  # @param assessment_id [String] UUID
  # @param context [Symbol] :self, :manager, or :alignment
  # @param active_category_id [String, nil] selected category tab
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  def initialize(matrix_data:, assessment_id:, context: :self,
                 active_category_id: nil, expanded_capability_id: nil)
    @matrix_data = matrix_data
    @assessment_id = assessment_id
    @context = context
    @active_category_id = active_category_id || first_category_id
    @expanded_capability_id = expanded_capability_id
  end

  def view_template
    div(data: { controller: "matrix", matrix_url_sync_value: true }) do
      render Views::Assessments::CategoryTabs.new(
        categories: @matrix_data[:categories],
        scoring: primary_scoring,
        active_category_id: @active_category_id,
        assessment_id: @assessment_id,
        context: @context
      )
      div(class: "overflow-x-auto") do
        table(class: "w-full border-collapse") do
          render Views::Assessments::MatrixHeader.new(
            merged_levels: @matrix_data[:merged_levels],
            person_level: @matrix_data[:person_level],
            inferred_level: @matrix_data[:inferred_level]
          )
          tbody do
            active_category = find_active_category
            if active_category
              render Views::Assessments::AssessmentCategoryGroup.new(
                category_data: active_category,
                merged_levels: @matrix_data[:merged_levels],
                person_level: @matrix_data[:person_level],
                scoring: @matrix_data[:scoring],
                self_scoring: @matrix_data[:self_scoring],
                manager_scoring: @matrix_data[:manager_scoring],
                aligned_scoring: @matrix_data[:aligned_scoring],
                assessment_id: @assessment_id,
                context: @context,
                expanded_capability_id: @expanded_capability_id,
                show_header: false
              )
            end
          end
        end
      end
    end
  end

  private

  def first_category_id
    @matrix_data[:categories].first&.dig(:category)&.category_id
  end

  def find_active_category
    @matrix_data[:categories].find { |c| c[:category].category_id == @active_category_id }
  end

  # Returns the primary scoring hash based on the current context.
  #
  # @return [Hash]
  def primary_scoring
    case @context
    when :self      then @matrix_data[:self_scoring] || @matrix_data[:scoring]
    when :manager   then @matrix_data[:manager_scoring] || @matrix_data[:scoring]
    when :alignment then @matrix_data[:aligned_scoring] || @matrix_data[:scoring]
    else @matrix_data[:scoring]
    end
  end
end
