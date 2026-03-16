# frozen_string_literal: true

# Turbo Frame wrapper for the matrix endpoint.
#
# Renders the matrix inside a <turbo-frame> tag so that
# Turbo can swap just this content on role selection changes.
#
class Views::Frameworks::MatrixFrameView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param selected_role_ids [Array<String>]
  def initialize(framework:, matrix_data:, selected_role_ids:)
    @framework = framework
    @matrix_data = matrix_data
    @selected_role_ids = selected_role_ids
  end

  def view_template
    turbo_frame_tag("framework-matrix") do
      render Views::Frameworks::Explorer::Matrix.new(
        matrix_data: @matrix_data,
        selected_role_ids: @selected_role_ids
      )
    end
  end
end
