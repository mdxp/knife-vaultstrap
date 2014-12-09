# Author:: Paul Mooring <paul@chef.io>
# Copyright:: Copyright (c) 2014 Chef Software, Inc.
# All rights reserved
#

module KnifeVaultstrap
  class Vaultstrap < Chef::Knife
    banner "knife vaultstrap [options]"

    # Don't lazy load or you'll get an error
    require 'chef/environment'
    require 'chef/node'
    require 'chef/role'
    require 'chef/api_client'
    # Do lazy load this stuff
    deps do
      require 'highline'
      require 'fog'
      require 'readline'
      require 'chef/search/query'
      require 'chef/mixin/command'
      require 'chef/knife/bootstrap'
      require 'chef/knife/ec2_base'
      require 'chef/knife/ec2_server_create'
      Chef::Knife::Bootstrap.load_deps
    end

    option :run_list,
        :short => "-r RUN_LIST",
        :long => "--run-list RUN_LIST",
        :description => "Comma separated list of roles/recipes to apply",
        :proc => lambda { |o| o.split(/[\s,]+/) }

    option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username",
        :default => "root"

    option :identity_file,
        :short => "-i IDENTITY_FILE",
        :long => "--identity-file IDENTITY_FILE",
        :description => "The SSH identity file used for authentication"

    option :vault_items,
        :long => "--vault-items vault_items",
        :description => "Comma separated vault items to apply",
        :proc => lambda { |o| o.split(/[\s,]+/) }

    option :use_sudo,
        :long => "--sudo",
        :description => "Execute the bootstrap via sudo",
        :boolean => true

    option :ssh_key_name,
        :short => "-S KEY",
        :long => "--ssh-key KEY",
        :description => "The AWS SSH key id",
        :proc => Proc.new { |key| Chef::Config[:knife][:aws_ssh_key_id] = key }

    option :aws_access_key_id,
        :short => "-A ID",
        :long => "--aws-access-key-id KEY",
        :description => "Your AWS Access Key ID",
        :proc => Proc.new { |key| Chef::Config[:knife][:aws_access_key_id] = key }

    option :aws_secret_access_key,
        :short => "-K SECRET",
        :long => "--aws-secret-access-key SECRET",
        :description => "Your AWS API Secret Access Key",
        :proc => Proc.new { |key| Chef::Config[:knife][:aws_secret_access_key] = key }

    option :region,
        :long => "--region REGION",
        :description => "Your AWS region",
        :proc => Proc.new { |key| Chef::Config[:knife][:region] = key }

    option :flavor,
        :short => "-f FLAVOR",
        :long => "--flavor FLAVOR",
        :description => "The flavor of server (m1.small, m1.medium, etc)",
        :proc => Proc.new { |f| Chef::Config[:knife][:flavor] = f }

    option :image,
        :short => "-I IMAGE",
        :long => "--image IMAGE",
        :description => "The AMI for the server",
        :proc => Proc.new { |i| Chef::Config[:knife][:image] = i }

    option :security_groups,
        :short => "-G X,Y,Z",
        :long => "--groups X,Y,Z",
        :description => "The security groups for this server; not allowed when using VPC",
        :proc => Proc.new { |groups| groups.split(',') }

    option :security_group_ids,
        :short => "-g X,Y,Z",
        :long => "--security-group-ids X,Y,Z",
        :description => "The security group ids for this server; required when using VPC",
        :proc => Proc.new { |security_group_ids| security_group_ids.split(',') }

    option :availability_zone,
        :short => "-Z ZONE",
        :long => "--availability-zone ZONE",
        :description => "The Availability Zone",
        :proc => Proc.new { |key| Chef::Config[:knife][:availability_zone] = key }

    option :preseed_attributes,
        :short => "-p JSON",
        :long => "--preseed-attributes JSON",
        :description => "Attributes to pre-seed the node with",
        :proc => Proc.new { |json_attrs| Chef::Config[:knife][:preseed_attributes] = JSON.parse(json_attrs) }

    option :bootstrap_version,
      :long => "--bootstrap-version VERSION",
      :description => "The version of Chef to install",
      :proc => lambda { |v| Chef::Config[:knife][:bootstrap_version] = v }

    option :bootstrap_proxy,
        :long => "--bootstrap-proxy PROXY_URL",
        :description => "The proxy server for the node being bootstrapped",
        :proc => Proc.new { |p| Chef::Config[:knife][:bootstrap_proxy] = p }

    option :bootstrap_chef_server_url,
        :long => "--bootstrap-chef-server-url CHEF_SERVER_URL",
        :description => "URL to use on the bootstrapped node if different than the local config",
        :proc => Proc.new { |c| Chef::Config[:knife][:bootstrap_chef_server_url] = c }

    option :node_hostname,
        :long => "--hostname HOSTNAME",
        :description => "Hostname or IP address of new node"

    option :node_chefname,
        :long => '--chef-node-name NAME',
        :description => "Name of the new client and node in Chef"

    def run
      if config[:node_hostname]
        node_host = config[:node_hostname]
        node_name = config[:node_chefname]
      else
        server = create_ec2_instance
        node_name = server.id
        node_host = server.dns_name
      end

      # Create the API client
      puts "Creating client"
      temp_dir = Dir.tmpdir
      Chef::ApiClient::Registration.new(node_name, "#{temp_dir}/#{node_name}.pem").run
      # Create the node
      new_node = Chef::Node.new
      new_node.name(node_name)
      new_node.normal_attrs = Chef::Config[:knife][:preseed_attributes]
      # The node is create as the client so acls look like we expect
      client_rest = Chef::REST.new(
                      Chef::Config.chef_server_url,
                      node_name,
                      "#{temp_dir}/#{node_name}.pem")
      puts "Creating node"
      client_rest.post_rest("nodes/", new_node)

      # Update vault items
      if config[:vault_items].class == Array
        puts "Waiting 60 seconds for search to populate"
        sleep 60
        config[:vault_items].each do |item|
          update_vault(item, "name:#{node_name}")
        end
      end

      bootstrap_node(node_name, node_host, "#{temp_dir}/#{node_name}.pem")
    end

    def ec2_creater
      unless @ec2_creater
        @ec2_creater = Chef::Knife::Ec2ServerCreate.new
        Chef::Config.knife.configuration.each do |k,v|
          @ec2_creater.config[k] = v
        end
      end

      @ec2_creater
    end

    def locate_config_value(key)
      key = key.to_sym
      config[key] || Chef::Config[:knife][key]
    end

    def create_ec2_instance
      unless Chef::Config[:knife][:aws_credential_file].nil?
        unless (Chef::Config[:knife].keys & [:aws_access_key_id, :aws_secret_access_key]).empty?
          errors << "Either provide a credentials file or the access key and secret keys but not both."
        end

        aws_creds = []
        File.read(Chef::Config[:knife][:aws_credential_file]).each_line do | line |
          aws_creds << line.split("=").map(&:strip) if line.include?("=")
        end
        entries = Hash[*aws_creds.flatten]
        Chef::Config[:knife][:aws_access_key_id] = entries['AWSAccessKeyId'] || entries['aws_access_key_id']
        Chef::Config[:knife][:aws_secret_access_key] = entries['AWSSecretKey'] || entries['aws_secret_access_key']
      end

      server = ec2_creater.connection.servers.create(ec2_creater.create_server_def)
      puts "Waiting on EC2 server:"
      server.wait_for { print  "."; ready? }
      puts "\nID: #{server.id}\nDNS: #{server.dns_name}"
      server
    end

    def bootstrap_node(server_name, ssh_host, client)
      bootstrap = Chef::Knife::Bootstrap.new
      Chef::Config.knife.configuration.each do |k,v|
        bootstrap.config[k] = v
      end

      bootstrap.name_args = [ssh_host]
      bootstrap.config[:verbosity] = config[:verbosity]
      bootstrap.config[:run_list] = config[:run_list]
      bootstrap.config[:bootstrap_version] = locate_config_value(:bootstrap_version)
      bootstrap.config[:distro] = locate_config_value(:distro)
      bootstrap.config[:template_file] = "#{File.dirname(__FILE__)}/../../templates/knife_vaultstrap_template.erb"
      bootstrap.config[:environment] = locate_config_value(:environment)
      bootstrap.config[:prerelease] = config[:prerelease]
      bootstrap.config[:first_boot_attributes] = locate_config_value(:json_attributes) || {}
      bootstrap.config[:encrypted_data_bag_secret] = locate_config_value(:encrypted_data_bag_secret)
      bootstrap.config[:encrypted_data_bag_secret_file] = locate_config_value(:encrypted_data_bag_secret_file)
      bootstrap.config[:secret] = locate_config_value(:secret)
      bootstrap.config[:secret_file] = locate_config_value(:secret_file)
      bootstrap.config[:bootstrap_version] = locate_config_value(:bootstrap_version)
      bootstrap.config[:bootstrap_proxy] = locate_config_value(:bootstrap_proxy)
      Chef::Config[:chef_server_url] = locate_config_value(:bootstrap_chef_server_url) if locate_config_value(:bootstrap_chef_server_url)
      bootstrap.config[:ssh_user] = config[:ssh_user] || 'ubuntu'
      bootstrap.config[:ssh_port] = config[:ssh_port]
      bootstrap.config[:ssh_gateway] = config[:ssh_gateway]
      bootstrap.config[:identity_file] = config[:identity_file]
      bootstrap.config[:use_sudo] = true unless config[:ssh_user] == 'root'
      # may be needed for vpc_mode
      bootstrap.config[:host_key_verify] = config[:host_key_verify]
      bootstrap.config[:chef_node_name] = server_name
      bootstrap.config[:client_pem] = client

      bootstrap.run
    end

    def update_vault(item, search, vault = 'vault')
      vault_item = ChefVault::Item.load(vault, item)
      vault_item.clients(search)

      vault_item.save
    end
  end
end
