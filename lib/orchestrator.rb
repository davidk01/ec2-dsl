require 'bundler/setup'
require 'aws-sdk'
require_relative './argvalidator'
require_relative './logging'
require_relative './provisioners'

##
# Contains the methods and classes for the configuration DSL to work.

class Orchestrator

  ##
  # Keep track of instances and their configurations.
  
  def initialize
    @instances = []
    # Used to cache any resources we have already loaded
    @resources = {}
  end

  ##
  # Parameter validation.
  
  def required(*opts)
    RequiredArgumentsValidator.new(*opts)
  end

  ##
  # Entry point into configuration DSL.
  
  def self.configure(opts = {}, &blk)
    instance = new
    instance.required(:region).validate(opts)
    # Update AWS configuration with region
    L::logger.info { "Setting AWS region: #{opts[:region]}" }
    Aws.config.update(:region => opts[:region])
    instance.instance_eval(&blk)
    instance
  end

  ##
  # Instantiate AWS resource and cache it. We cache things because they are unique
  # and we don't want to make unnecessary API calls for validating resources.
  
  def load_resource!(resource_klass, id)
    @resources[id] ||= resource_klass.new(id).load
    unless @resources[id].state == "available"
      raise StandardError, "Resource not available: #{id}"
    end
    @resources[id]
  end

  ##
  # Load AMI.
  
  def ami(image_id)
    load_resource!(Aws::EC2::Image, image_id)
  end

  ##
  # Same as above.
  
  def subnet(subnet_id)
    load_resource!(Aws::EC2::Subnet, subnet_id)
  end

  ##
  # Same as above.
  
  def vpc(vpc_id)
    load_resource!(Aws::EC2::Vpc, vpc_id)
  end

  ##
  # Can't use +load_resource!+ because +KeyPairInfo+ instances do not have state method.
  
  def keypair(keypair_name)
    @resources[keypair_name] ||= Aws::EC2::KeyPairInfo.new(keypair_name).load
  end

  ##
  # No need to cache because does not require API call.
  
  def keyfile(file_name)
    Keyfile.new(file_name)
  end

  ##
  # No +state+ method so can't use +load_resources!+.
  
  def sg(sg_id)
    @resources[sg_id] ||= Aws::EC2::SecurityGroup.new(sg_id).load
  end

  ##
  # No need to cache because does not require API calls.
  
  def instance_type(t)
    InstanceType.new(t)
  end

  ##
  # Same as above.
  
  def drive(opts = {})
    Drive.new(opts)
  end

  ##
  # No need to cache because no API calls are made.
  
  def snapshot(opts = {})
    DriveSnapshot.new(opts)
  end

  ##
  # Script provisioner.
  
  def script(opts = {})
    Script.new(opts)
  end

  ##
  # Tar provisioner.
  
  def tar(opts = {})
    Tar.new(opts)
  end

  ##
  # Directory provisioner.
  
  def dir(opts = {})
    Directory.new(opts)
  end

  ##
  # Same as above.
  
  def tag(key, value)
    Tag.new(key, value)
  end

  ##
  # This just creates an instance definition and returns it to caller.
  
  def instance(opts = {})
    required(:ami, :subnet, :vpc, :keypair, :keyfile, :tags, :ssh_user,
             :security_groups, :type, :ebs, :bootstrap).validate(opts)
    Instance.new(opts)
  end

  ##
  # This is the one that adds the instance to the list of instances. I'm keeping them
  # separate because I want to call out side-effecting operations that modify the configuration
  # context.
  
  def instance!(opts = {})
    L::logger.info { "Adding instance to instance list." }
    @instances << instance(opts)
  end

  ##
  # Now go ahead and initialize all the accumulated instances and run all the
  # required SSH commands on them.
  
  def provision
    if @instances.empty?
      raise StandardError, "There are no instances to provision."
    end
    L::logger.info { "Instantiating EC2 instances." }
    @instances.each(&:instantiate!)
    L::logger.info { "Bootstrapping EC2 instances with SSH." }
    @instances.each(&:bootstrap!)
  end

end

##
# Used to tag resources.

class Tag

  def initialize(key, value)
    @key, @value = key, value
  end

  ##
  # Convert to format for +create_tags+ method.
  
  def mappify
    {:key => @key, :value => @value}
  end

end

##
# EC2 instance configuration.

class Instance

  def initialize(opts)
    @opts = opts
  end

  ##
  # Used by bootstrappers to know where to SSH.
  
  def private_ip
    @instance.private_ip_address
  end

  ##
  # Convenient for displaying error messages that require instance id.
  
  def id
    @instance.id
  end

  ##
  # Used for bootstrapping.
  
  def ssh_user
    @opts[:ssh_user]
  end

  ##
  # Used for bootstrapping.
  
  def keyfile
    @opts[:keyfile]
  end

  ##
  # Pick up the provisioners and use SSH shelling out to configure the instance.
  
  def bootstrap!
    L::logger.info { "Running sequence of bootstrap command: #{id}." }
    @opts[:bootstrap].each {|b| b.bootstrap!(self)}
  end

  ##
  # Spin up the instance, make the EBS drives, wait for instance to be ready,
  # attach EBS drives, tag everything.
  
  def instantiate!
    client = Aws::EC2::Client.new
    @reservation = client.run_instances({
      :image_id => @opts[:ami].id,
      :min_count => 1,
      :max_count => 1,
      :key_name => @opts[:keypair].name,
      # See https://github.com/boto/boto/issues/350
      :security_group_ids => @opts[:security_groups].map(&:id),
      :instance_type => @opts[:type].name,
      :block_device_mappings => @opts[:ebs].map(&:mappify),
      :subnet_id => @opts[:subnet].id,
      :disable_api_termination => false,
      instance_initiated_shutdown_behavior: "terminate"
    })
    # Wait until instance is ready
    instance_id = @reservation.instances[0].instance_id
    L::logger.info { "Instance reservation created: #{instance_id}." }
    @reservations = client.describe_instances(:instance_ids => [instance_id]).reservations
    max_retries, retried = 20, 0
    L::logger.info { "Waiting for instance to transition to 'running' state: #{instance_id}." }
    while @reservations[0].instances[0].state.name != "running"
      if retried > max_retries
        raise StandardError, "Instance did not become ready: #{instance_id}"
      end
      sleep 10
      @reservations = client.describe_instances(:instance_ids => [instance_id]).reservations
      retried += 1
    end
    # Grab the instance and create the tags
    @instance = Aws::EC2::Instance.new(instance_id)
    L::logger.info { "Tagging instance: #{instance_id}." }
    @instance.create_tags(:tags => @opts[:tags].map(&:mappify))
    # Grab the block device mapping and tag the volumes
    L::logger.info { "Attaching and tagging EBS volumes: #{instance_id}." }
    @block_devices = @instance.block_device_mappings.map do |device| 
      volume_id = device.ebs.volume_id
      device_name = device.device_name
      volume = Aws::EC2::Volume.new(volume_id)
      # Find the volume configuration and tag it, skip any devices we don't know about
      volume_configuration = @opts[:ebs].select {|config| config.name == device_name}.first
      # Tagging a volume will also store the volume instance inside the configuration
      volume_configuration.tag_volume!(volume) unless volume_configuration.nil?
      volume_configuration
    end
    L::logger.info { "EBS volumes tagged and attached: #{instance_id}." }
    # At this point the instance is fully configured and we can try to SSH and run scripts
  end

end

class InstanceType

  @@types = %w{t1.micro m1.small m1.medium m1.large m1.xlarge m3.medium
           m3.large m3.xlarge m3.2xlarge m4.large m4.xlarge m4.2xlarge
           m4.4xlarge m4.10xlarge t2.micro t2.small t2.medium t2.large
           m2.xlarge m2.2xlarge m2.4xlarge cr1.8xlarge i2.xlarge i2.2xlarge
           i2.4xlarge i2.8xlarge hi1.4xlarge hs1.8xlarge c1.medium c1.xlarge
           c3.large c3.xlarge c3.2xlarge c3.4xlarge c3.8xlarge c4.large c4.xlarge
           c4.2xlarge c4.4xlarge c4.8xlarge cc1.4xlarge cc2.8xlarge g2.2xlarge
           cg1.4xlarge r3.large r3.xlarge r3.2xlarge r3.4xlarge r3.8xlarge d2.xlarge
           d2.2xlarge d2.4xlarge d2.8xlarge}
  
  def initialize(instance_type)
    @instance_type = instance_type
    validate
  end

  def name
    @instance_type
  end

  def validate
    unless @@types.include?(@instance_type)
      raise StandardError, "Invalid instance type: #{@instance_type}."
    end
  end

end

##
# Corresponds to EBS drive.

class Drive

  def initialize(opts)
    @opts = opts
    validate
  end

  def name
    @opts[:name]
  end

  ##
  # Add the tags to the volume, same as we do for the EC2 instance.
  
  def tag_volume!(volume)
    @volume = volume
    @volume.create_tags(:tags => @opts[:tags].map(&:mappify))
  end

  ##
  # Convert to hash format acceptable for instance creation.
  
  def mappify
    {
      :device_name => @opts[:name],
      :ebs => {
        :volume_size => @opts[:size],
        :delete_on_termination => true,
        :volume_type => @opts[:type],
        :encrypted => false
      }
    }
  end

  ##
  # Do some basic validation before we are ready to create and attach the volume
  # to an instance.
  
  def validate
    RequiredArgumentsValidator.new(:name, :size, :type, :tags).validate(@opts)
    unless @opts[:name].start_with?("/dev/sd")
      raise StandardError, "Drive name must start with '/dev/sd*'."
    end
    size = @opts[:size]
    unless size > 0
      raise StandardError, "Size must be greater than 0: #{size}"
    end
    type = @opts[:type]
    unless ["standard", "io1", "gp2"].include?(type)
      raise StandardError, "Type must be one of: 'standard', 'io1', 'gp2'."
    end
  end

end

##
# Corresponds to EBS snapshot mount.

class DriveSnapshot < Drive

  ##
  # Same as above. Almost.
  
  def mappify
    {
      :device_name => @opts[:name],
      :ebs => {
        :delete_on_termination => true,
        :volume_type => @opts[:type],
        :snapshot_id => @snapshot.id,
      }
    }
  end

  ##
  # Similar to above.
  
  def validate
    RequiredArgumentsValidator.new(:name, :snapshot, :tags).validate(@opts)
    # See http://stackoverflow.com/questions/24346302/launching-with-snapshot-based-volume-fails
    unless @opts[:name][%r{^/dev/sd[f-p]}]
      raise StandardError, "Drive name must start with '/dev/sd[f-p]'."
    end
    id = @opts[:snapshot]
    @snapshot = Aws::EC2::Snapshot.new(id)
    @snapshot.load
  end

end

##
# Just contains path to a file.

class Keyfile

  attr_reader :path

  def initialize(path)
    @path = File.expand_path(path)
    if !File.exist?(@path)
      raise StandardError, "File does not exist: #{@path}"
    end
  end

end
