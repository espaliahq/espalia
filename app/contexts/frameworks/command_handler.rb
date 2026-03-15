# frozen_string_literal: true

# Handles commands for the Framework aggregate.
#
# Loads the aggregate via the repository, executes the command,
# and stores resulting events.
#
class Frameworks::CommandHandler
  # @param repository [Frameworks::Repository]
  def initialize(repository: Frameworks::Repository.new)
    @repository = repository
  end

  # Creates a new framework.
  #
  # @param framework_id [String] UUID for the new framework
  # @param name [String] display name
  def create_framework(framework_id, name)
    @repository.with_framework(framework_id) do |framework|
      framework.create(framework_id, name)
    end
  end
end
