module Awsborn
  class Server
    
    def initialize (name, options = {})
      @name = name
      @options = options.dup
      self.host_name = elastic_ip
    end
    
    class << self
      attr_accessor :logger
      def image_id (*args)
        unless args.empty?
          @image_id = args.first
          @sudo_user = args.last[:sudo_user] if args.last.is_a?(Hash)
        end
        @image_id
      end
      def instance_type (*args)
        @instance_type = args.first unless args.empty?
        @instance_type
      end
      def security_group (*args)
        @security_group = args.first unless args.empty?
        @security_group
      end
      def keys (*args)
        @keys = args unless args.empty?
        @keys
      end
      def sudo_user (*args)
        @sudo_user = args.first unless args.empty?
        @sudo_user
      end
      def bootstrap_script (*args)
        @bootstrap_script = args.first unless args.empty?
        @bootstrap_script
      end
      
      def cluster (&block)
        ServerCluster.build self, &block
      end
      def logger
        @logger ||= Awsborn.logger
      end
    end

    def one_of_my_disks_is_attached_to_a_running_instance?
      vol_id = disk.values.first
      ec2.volume_has_instance?(vol_id)
    end
    alias :running? :one_of_my_disks_is_attached_to_a_running_instance?

    def start (key_pair)
      launch_instance(key_pair)

      update_known_hosts
      install_ssh_keys(key_pair)

      associate_address
      update_known_hosts

      bootstrap
      attach_volumes
    end

    def launch_instance (key_pair)
      @launch_response = ec2.launch_instance(image_id,
        :instance_type => constant(instance_type),
        :availability_zone => constant(zone),
        :key_name => key_pair.name,
        :group_ids => security_group
      )
      logger.debug @launch_response

      Awsborn.wait_for("instance #{instance_id} (#{name}) to start", 10) { instance_running? }
      self.host_name = aws_dns_name
    end

    def update_known_hosts
      KnownHostsUpdater.update_for_server self
    end
    
    def install_ssh_keys (temp_key_pair)
      cmd = "ssh -i #{temp_key_pair.path} #{sudo_user}@#{aws_dns_name} 'cat > .ssh/authorized_keys'"
      logger.debug cmd
      IO.popen(cmd, "w") do |pipe|
        pipe.puts key_data
      end
      system("ssh #{sudo_user}@#{aws_dns_name} 'sudo cp .ssh/authorized_keys /root/.ssh/authorized_keys'")
    end

    def key_data
      Dir[*keys].inject([]) do |memo, file_name|
        memo + File.readlines(file_name).map { |line| line.chomp }
      end.join("\n")
    end

    def path_relative_to_script (path)
      File.join(File.dirname(File.expand_path($0)), path)
    end
    
    def associate_address
      ec2.associate_address(elastic_ip)
      self.host_name = elastic_ip
    end

    def bootstrap
      if bootstrap_script
        script = path_relative_to_script(bootstrap_script)
        basename = File.basename(script)
        system "scp #{script} root@#{elastic_ip}:/tmp"
        system "ssh root@#{elastic_ip} 'cd /tmp && chmod 700 #{basename} && ./#{basename}'"
      end
    end
    
    def attach_volumes
      disk.each_pair do |device, volume|
        device = "/dev/#{device}" if device.is_a?(Symbol) || ! device.match('/')
        res = ec2.attach_volume(volume, device)
      end
    end

    def ec2
      @ec2 ||= Ec2.new(zone)
    end
    
    begin :accessors
      attr_accessor :name, :host_name, :logger
      def zone
        @options[:zone]
      end
      def disk
        @options[:disk]
      end
      def image_id
        self.class.image_id
      end
      def instance_type
        @options[:instance_type] || self.class.instance_type
      end
      def security_group
        @options[:security_group] || self.class.security_group
      end
      def sudo_user
        @options[:sudo_user] || self.class.sudo_user
      end
      def bootstrap_script
        @options[:bootstrap_script] || self.class.bootstrap_script
      end
      def keys
        @options[:keys] || self.class.keys
      end
      def elastic_ip
        @options[:ip]
      end
      def instance_id
        ec2.instance_id
      end
      def aws_dns_name
        describe_instance[:dns_name]
      end
      def launch_time
        xml_time = describe_instance[:aws_launch_time]
        logger.debug xml_time
        Time.xmlschema(xml_time)
      end
      def instance_running?
        describe_instance![:aws_state] == 'running'
      end
      def describe_instance!
        @describe_instance = nil
        logger.debug describe_instance
        describe_instance
      end
      def describe_instance
        @describe_instance ||= ec2.describe_instance
      end
    end
    
    def constant (symbol)
      {
        :us_east_1a => "us-east-1a",
        :us_east_1b => "us-east-1b",
        :us_east_1c => "us-east-1c",
        :us_west_1a => "us-west-1a",
        :us_west_1b => "us-west-1b",
        :eu_west_1a => "eu-west-1a",
        :eu_west_1b => "eu-west-1b",
        :m1_small   => "m1.small",
        :m1_large   => "m1.large" ,
        :m1_xlarge  => "m1.xlarge",
        :m2_2xlarge => "m2.2xlarge",
        :m2_4xlarge => "m2.4xlarge",
        :c1_medium  => "c1.medium",
        :c1_xlarge  => "c1.xlarge"
      }[symbol]
    end

    def logger
      @logger ||= self.class.logger
    end
    
  end
end
