require 'json'
require 'jenkins_api_client'
require 'nokogiri'
require_relative './argvalidator'
require_relative './logging'

class JenkinsState

  ##
  # Wrapper around the scraped Nokogiri build queue.
  
  class BuildQueue

    def initialize(nokogiri_elements)
      @jobs = nokogiri_elements
    end

    def empty?
      @jobs.empty?
    end

  end

  ##
  # Encapsulates instances of Jenkins workers.

  class Worker

    def initialize(opts = {})
      RequiredArgumentsValidator.new(:json_data, :parent).validate(opts)
      @json_data, @parent = opts[:json_data], opts[:parent]
    end

    ##
    # IP address of the worker. I gave up on scraping and just encode the address as 
    # part of name, e.g. "worker - $ip". This means that any instances that do not follow
    # this convention will go unseen by this library.
    
    def ip
      address = name.split(' - ')[1]
      unless address =~ /(\d+\.){3}\d+/
        raise StandardError, "IP address does not look correct: #{address}."
      end
      address
    end

    def name
      @json_data['displayName']
    end

    ##
    # Is the worker busy or not. Who knows. Weird race condition here but gonna ignore.
    
    def free?
      @json_data['idle']
    end

  end

  ##
  # Expose username and password because +Worker+ instances will need it to
  # scrape their own IP address
  
  attr_reader :username, :password

  def initialize(opts = {})
    RequiredArgumentsValidator.new(:host, :port, :username, :password,
                                   :credentials_id).validate(opts)
    @host, @port = opts[:host], opts[:port]
    @username, @password = opts[:username], opts[:password]
    @credentials_id = opts[:credentials_id]
  end

  ##
  # Busts the worker cache so that we call the API endpoint again
  
  def workers!
    L::logger.info('Busting Jenkins worker cache.')
    @workers = nil
    workers
  end

  ##
  # Get all the workers and encapsulate them as +Worker+ objects. Caches the results
  # so be wary. To bypass the cache use +workers!+
  
  def workers
    return @workers if @workers
    endpoint = "#{@host}:#{@port}/computer/api/json"
    response = `curl -u '#{@username}':'#{@password}' '#{endpoint}'`
    if response.empty?
      raise StandardError, "Empty response from endpoint: #{endpoint}"
    end
    begin
      json = JSON.load(response)
    rescue Exception => ex
      STDERR.puts "Failed to load data from #{endpoint}"
      raise ex
    end
    # filter out master node
    @workers = json['computer'].map do |c| 
      if c['displayName'] == 'master'
        nil
      else
        Worker.new(:json_data => c, :parent => self)
      end
    end.reject(&:nil?)
  end

  ##
  # Find a worker by IP address or return +nil+ to indicate not found
  
  def worker_by_ip(ip_address)
    workers.select {|w| w.ip == ip_address}.first
  end

  ##
  # Just interpolate strings to generate the endpoint we are going to cURL.
  # TODO: Convert to URI based formatter.
  
  def endpoint
    "http://#{@host}:#{@port}"
  end

  ##
  # Use the Jenkins gem to instantiate a client.
  
  def jenkins_client
    JenkinsApi::Client.new({
      :username => @username, :password => @password,
      :server_url => endpoint})
  end

  ##
  # Remove the worker from Jenkins. +w+ is +JenkinsState::Worker+ instance.
  
  def delete_worker(w)
    L::logger.info { "Deleting worker: #{w.name}" }
    node = JenkinsApi::Client::Node.new(jenkins_client)
    node.delete(w.name)
  end

  ##
  # +w+ is a +TFSate::WorkerResource+ instance.
  # TODO: Fix this so it is agnostic of TFState or any other resource type.

  def register_worker(w)
    worker_name = "worker - #{w.ip}"
    L::logger.info { "Registering worker: #{worker_name}" }
    node = JenkinsApi::Client::Node.new(jenkins_client)
    # TODO: These all need to be configurable values
    node.create_dumb_slave({
      :remote_fs => "/var/lib/jenkins", 
      :private_key_file => "/var/lib/jenkins/.ssh/jenkins",
      :name => worker_name, :credentials_id => @credentials_id, 
      :slave_host => w.ip, :executors => 10})
  end

  ##
  # The work queue. cURL the endpoint and parse out the results with Nokogiri.
  
  def queue
    html = `curl -u '#{@username}':'#{@password}' #{endpoint}`
    doc = Nokogiri::HTML(html)
    queue_elements = doc.css('#buildQueue .pane tr td a.model-link')
    BuildQueue.new(queue_elements)
  end

end
