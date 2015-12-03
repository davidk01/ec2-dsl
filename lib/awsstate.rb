require_relative './argvalidator'
require 'aws-sdk'

class AWSState

  ##
  # Wraps AWS reservation for convenient access to certain attributes.
  
  class Node

    ##
    # Just keep track of the reservation
    
    def initialize(reservation)
      @reservation = reservation
    end

    ##
    # Private IP address.
    
    def ip
      @reservation.instances.first.private_ip_address
    end

    ##
    # Is it in 'running' state?
    
    def running?
      @reservation.instances.first.state.name == "running"
    end

    ##
    # The SDK actually does the right thing here and returns a Time object.
    
    def launch_time
      @reservation.instances.first.launch_time
    end

    ##
    # Kills the instance.
    
    def terminate!
      Aws::EC2::Instance.new(@reservation.instances.first.instance_id).terminate
    end

  end

  ##
  # Wrap the necessary pieces for querying AWS for instance information.
  
  def initialize(opts = {})
    @opts = opts
    RequiredArgumentsValidator.new(:region).validate(@opts)
    Aws.config.update(:region => @opts[:region])
  end

  ##
  # Figure out if the node satisfies the uptime requirements and kill it if it does.
  # We pay by the hour so we only kill nodes that are close to the hour mark in terms
  # of uptime otherwise we are wasting money and can get into weird loops where we
  # create and destroy nodes too frequently because of erratic queue behavior.
  
  def destroy_worker(worker)
    address = worker.ip
    node = resources_by_ip(address).first
    if node.nil?
      L::logger.info { "Did not find node: #{address}. Not doing anything." }
      return
    end
    launch_time = node.launch_time
    # uptime is in seconds so we convert to minutes and then mod by 60 to get minute component
    uptime = Time.now - launch_time
    minutes = (uptime / 60) % 60
    # if we are between 45 and 59 minutes then safe to kill because we've made use of it long
    # enough
    if minutes > 45 && minutes < 59
      L::logger.info { "Terminating node: #{address}" }
      node.terminate!
    else
      L::logger.info { "Not terminating node: #{address}. Uptime minutes: #{uptime / 60}" }
    end
  end

  ##
  # Select all nodes from a specific region matching specific tags and cache the
  # results because we don't want keep hitting the API over and over again.
  
  def nodes(opts = {})
    RequiredArgumentsValidator.new(:tag).validate(opts)
    tagged_nodes = nodes_by_tag(opts)
  end

  ##
  # Generate wrapper around reservation instance.
  
  def nodify(reservation)
    Node.new(reservation)
  end

  ##
  # Get the AWS::EC2 client. Makes a new one every time. Not sure if necessary but might as
  # well. Is probably better in multi-threaded and multi-process scenarios.
  
  def client
    Aws::EC2::Client.new
  end

  ##
  # This is the caching version, to bust the cache call the ! version.
  
  def nodes_by_tag(opts = {})
    RequiredArgumentsValidator.new(:tag).validate(opts)
    RequiredArgumentsValidator.new(:key, :value).validate(opts[:tag])
    return @nodes unless @nodes.nil?
    # Didn't have it in the cache so go ahead and query AWS for the information
    key, value = opts[:tag][:key], opts[:tag][:value]
    @nodes = client.describe_instances({
      :filters => [
        {
          :name => 'tag:' + key, :values => [value]
        } 
      ]
    }).reservations.map {|n| nodify(n)}
    @nodes
  end

  ##
  # Find the instances by internal IP addresses.
  # TODO: This could become problematic so figure out if we need to cache.
  
  def resources_by_ip(*ip_address)
    reservation = client.describe_instances({
      :filters => [
        {
          :name => 'private-ip-address', :values => ip_address
        }
      ]
    }).reservations.map {|r| nodify(r)}
  end

  ##
  # Bust the cache and then call +nodes_by_tag+.
  
  def nodes_by_tag!(opts = {})
    @nodes = nil
    nodes_by_tag(opts)
  end

end
