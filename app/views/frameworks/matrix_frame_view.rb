# frozen_string_literal: true

# Turbo Frame wrapper for the matrix endpoint.
#
# Renders the matrix inside a <turbo-frame> tag so that
# Turbo can swap just this content on role selection changes.
#
class Views::Frameworks::MatrixFrameView < Views::Base
  # @param framework [FrameworkState::Framework, Frameworks::ExplorerGraph::Framework]
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param selected_role_ids [Array<String>]
  # @param mode [Symbol] :view or :edit
  def initialize(framework:, matrix_data:, selected_role_ids:, mode: :view)
    @framework = framework
    @matrix_data = matrix_data
    @selected_role_ids = selected_role_ids
    @mode = mode
  end

  def view_template
    turbo_frame_tag("framework-matrix") do
      render Views::Frameworks::Explorer::Matrix.new(
        matrix_data: @matrix_data,
        selected_role_ids: @selected_role_ids,
        framework_id: @framework.framework_id,
        mode: @mode
      )
    end
  end
end
