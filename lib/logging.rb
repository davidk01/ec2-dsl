require 'logger'

##
# Keeping logging stuff in one place.

module L

  @@logger = Logger.new(STDOUT)
  @@logger.level = Logger::INFO

  def self.logger
    @@logger
  end

end
