#!/usr/bin/env ruby
require 'bundler/setup'
require 'trollop'
require 'json'
require 'logger'
require_relative '../lib/jenkins'
require_relative '../lib/awsstate'
require_relative '../lib/orchestrator'

opts = Trollop::options do
  opt :jenkins_master, "IP or host name of Jenkins master server",
    :type => :string, :required => true
  opt :port, "Port of the Jenkins master server, e.g. 8080",
    :type => :int, :default => 8080
  opt :username, "Admin username for accessing Jenkins",
    :type => :string, :required => true
  opt :password, "Admin password for accessing Jenkins",
    :type => :string, :required => true
  opt :credentials_id, "The credential ID master will use to connect to worker",
    :type => :string, :required => true
  opt :pool, "The tagged pool of workers corresponding to the given master",
    :type => :string, :required => true
end

pool_name = opts[:pool]
region = 'us-west-2' # TODO: Probably should make this configurable as well
aws_state = AWSState.new(:region => region)
orchestrator = Orchestrator.configure(:region => region) do
  instance!(
    :ami => ami("ami-6cfcec0d"),
    :subnet => subnet("subnet-b0295ce9"),
    :tags => [
      tag('Name', 'Jenkins Worker'),
      tag('pool', pool_name) # This is important because this is how we search
    ],
    :vpc => vpc("vpc-d08aa1b5"),
    :keypair => keypair("pair name"),
    :keyfile => keyfile("~/.ssh/key.pem"),
    :ssh_user => "ubuntu",
    :security_groups => [
      sg("sg-1b54797f"), # default
      sg("sg-e5547981"), # nat
      sg("sg-e4547980") # bastion
    ],
    :type => instance_type("t2.micro"),
    :ebs => ["b", "c", "d", "e"].map do |l|
      drive(
        :name => "/dev/sd#{l}",
        :size => 150,
        :tags => [
          tag('Name', 'Jenkins Worker Drive')
        ],
        :type => "gp2"
      )
    end + [snapshot(:name => "/dev/sdf", :tags => [
      tag('Name', 'Jenkins Worker Drive')
    ], :snapshot => "snap-310a3b76")],
    :bootstrap => [
      dir(:path => "../scripts", :main => "worker-init.sh")
    ]
  )
end

# Load Jenkins state by scraping or curling API (same difference)
jenkins_state = JenkinsState.new(:host => opts[:jenkins_master], :port => opts[:port], 
  :username => opts[:username], :password => opts[:password],
  :credentials_id => opts[:credentials_id]) 

# First verify that the workers in Jenkins and the workers in +aws_state+ are synced up
# +resources_by_ip+ returns list of instances that match the ip addresses given
jenkins_ip_addresses = jenkins_state.workers.map(&:ip)
aws_nodes = aws_state.resources_by_ip(*jenkins_ip_addresses).select(&:running?)
defunct_workers = jenkins_state.workers.reject {|w| aws_nodes.any? {|n| n.ip == w.ip}}
# +delete_worker+ takes a worker and deletes it from the master
defunct_workers.each {|w| jenkins_state.delete_worker(w)}

# After removing the defunct workers we add any new workers that have come online
# +worker_by_ip+ is the same as +resource_by_ip+ in terms of return results
# Only select 'running' instances, otherwise we get confused with terminated instances
new_workers = aws_state.nodes(:tag => {:key => 'pool', :value => pool_name}).
  select(&:running?).reject {|w| jenkins_state.worker_by_ip(w.ip)}
# +register_worker+ does what you expect, i.e. registers worker with master
new_workers.each {|w| jenkins_state.register_worker(w)}

# At this point state is synchronized and if there any new workers then we bail
# because we want to give things some time to settle before deciding if we should add
# or remove worker nodes
exit if new_workers.any?

# We got this far means there are no new workers so we need to decide if we should
# increase or decrease the count of workers
free_workers = jenkins_state.workers.select {|w| w.free?}
queue = jenkins_state.queue
if queue.empty?
  # the queue is empty so find a free worker and shoot it in the head
  if free_workers.any? and free_workers.length > 1
    free_worker = free_workers.first
    aws_state.destroy_worker(free_worker)
  end
else
  # the queue is not empty so create more workers
  if free_workers.empty?
    orchestrator.provision
  end
end
