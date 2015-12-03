require_relative '../lib/orchestrator'

# Tell Orchestrator to create the instances
orchestrator = Orchestrator.configure(:region => 'us-west-2') do
  instance!(:ami => ami("ami-6cfcec0d"), 
           :subnet => subnet("subnet-73ca9f04"),
           :tags => [tag('Name', 'Jenkins Worker')],
           :vpc => vpc("vpc-b57f5cd0"), 
           :keypair => keypair("pair"),
           :keyfile => keyfile("~/.ssh/key.pem"),
           :ssh_user => "ubuntu",
           :security_groups => [sg("sg-2ee0bf4a"), sg("sg-8b7f2eef")],
           :type => instance_type("t2.micro"),
           :ebs => [drive(:name => "/dev/sdb", 
                          :size => 150, 
                          :tags => [tag('Name', 'Jenkins Worker Drive')],
                          :type => "gp2"),
                    snapshot(:name => "/dev/sdf", 
                             :tags => [tag('Name', 'Jenkins Worker Drive')],
                             :snapshot => "snap-310a3b76")],
           :bootstrap => [script(:path => "../startup-scripts/drive-maker.sh"), 
                          tar(:path => "../startup-scripts/drive-maker.sh")])
end

orchestrator.provision
