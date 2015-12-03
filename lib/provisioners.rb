require_relative './logging'
require_relative './argvalidator'

##
# Common functionality for provisioning through SSH.

class Bootstrap

  ##
  # Common options.

  @@options = "-o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o " +
    "StrictHostKeyChecking=no"

  ##
  # If we get any response back then assume SSH is ready.

  def ssh_ready?
    response = `ssh #{@options} #{@endpoint} 'uptime'`
    # If we got anything back then assume SSH is ready
    !response.empty?
  end

  ##
  # Wait until SSH connections can be made.

  def wait_for_ssh_ready
    L::logger.info { "Waiting for SSH to be ready." }
    retries, max_retries = 0, 20
    while !ssh_ready?
      if retries > max_retries
        raise StandardError, "SSH did not become ready: #{@id}"
      end
      retries += 1
      sleep 10
    end
  end

  ##
  # Common functionality is to just wait for SSH to be ready.

  def bootstrap!(instance_configuration)
    if @path.nil?
      raise StandardError, "Must call validate first"
    end
    @user, @ip, @key, @id = instance_configuration.ssh_user, instance_configuration.private_ip,
      instance_configuration.keyfile.path, instance_configuration.id
    @options = "#{@@options} -i '#{@key}'"
    @endpoint = "'#{@user}'@'#{@ip}'"
    wait_for_ssh_ready
  end

end

##
# Tar file bootstrapper.

class Tar < Bootstrap

  def initialize(opts)
    @opts = opts
    validate!
  end

  def bootstrap!(instance_configuration)
    super
    L::logger.info { "Copying tar file, unpacking, and executing setup.sh." }
    `scp #{@options} #{@path} #{@endpoint}:script.tar`
    `ssh #{@options} #{@endpoint} 'rm -rf tar; mkdir tar; tar xf script.tar -C tar'`
    `ssh #{@options} #{@endpoint} 'cd tar; sudo bash setup.sh'`
  end

  def validate!
    RequiredArgumentsValidator.new(:path).validate(@opts)
    @path = File.expand_path(@opts[:path])
    unless File.exist?(@path)
      raise StandardError, "Tar file path does not exist: #{@path}."
    end
  end

end

class Script < Bootstrap

  def initialize(opts)
    @opts = opts
    validate!
  end

  ##
  # Instance configuration contains all the information required to SSH into box and run
  # things. This sets up +@user+, +@ip+, +@key+, +@id+, +@options+, +@endpoint+.

  def bootstrap!(instance_configuration)
    super
    L::logger.info { "Copying script to script.sh and executing." }
    `scp #{@options} #{@path} #{@endpoint}:script.sh`
    `ssh #{@options} #{@endpoint} 'sudo bash script.sh'`
  end

  ##
  # Verify file path exists and set +@path+ instance variable.

  def validate!
    RequiredArgumentsValidator.new(:path).validate(@opts)
    @path = File.expand_path(@opts[:path])
    unless File.exist?(@path)
      raise StandardError, "Script file does not exist: #{@path}."
    end
  end

end

##
# Upload directory and execute specific script in directory.

class Directory < Bootstrap

  def initialize(opts = {})
    @opts = opts
    validate!
  end

  def validate!
    RequiredArgumentsValidator.new(:path, :main).validate(@opts)
    @path = File.expand_path(@opts[:path])
    if @path[-1] == '/'
      @path = @path[0..-2]
    end
    main = File.join(@path, @opts[:main])
    unless File.exists?(@path)
      raise StandardError, "Path does not exist: #{@path}"
    end
    unless File.exists?(main)
      raise StandardError, "Main script does not exist: #{main}"
    end
  end

  def bootstrap!(instance_configuration)
    super
    L::logger.info { "Copying directory into place and executing main script." }
    `ssh #{@options} #{@endpoint} 'sudo rm -rf directory'`
    `scp #{@options} -r #{@path} #{@endpoint}:directory`
    `ssh #{@options} #{@endpoint} 'cd directory; sudo bash #{@opts[:main]}'`
  end

end
