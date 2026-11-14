# frozen_string_literal: true

# A plan command refused for a reason its caller can read and act on: a blank
# name, a plan that was deleted. Operations show the message as it is.
class TeamPlanning::Error < StandardError; end
