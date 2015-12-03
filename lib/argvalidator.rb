##
# Validate keyword argument parameters.

class RequiredArgumentsValidator

  ##
  # Initialize with a list of required arguments.

  def initialize(*opts)
    @opts = opts
  end

  ##
  # Make sure only required arguments are included.

  def validate(options)
    keys = options.keys
    # First verify all required arguments are there
    @opts.each do |o|
      unless options.include?(o)
        raise StandardError, "Required argument is missing: #{o}"
      end
    end
    # Next verify there are no extra arguments
    extras = keys.reject {|o| @opts.include?(o)}
    if extras.any?
      raise StandardError, "Extra arguments found: #{extras.join(', ')}"
    end
  end

end
