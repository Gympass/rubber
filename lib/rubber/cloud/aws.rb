require 'fog'
require 'rubber/cloud/aws_storage'

module Rubber
  module Cloud
  
    class Aws < Base
      
      attr_reader :compute_provider, :storage_provider

      def initialize(env, capistrano)
        super(env, capistrano)
        credentials = {:aws_access_key_id => env.access_key,
                       :aws_secret_access_key => env.secret_access_key,
                       :region => env.region }
        
        @elb = ::Fog::AWS::ELB.new(credentials)
        
        credentials[:provider] = 'AWS'
        @compute_provider = ::Fog::Compute.new(credentials)
        @storage_provider = ::Fog::Storage.new(credentials)
      end
      
      def storage(bucket)
        return Rubber::Cloud::AwsStorage.new(@storage_provider, bucket)
      end

      def create_instance(ami, ami_type, security_groups, availability_zone)
        response = @compute_provider.servers.create(:image_id => ami,
                                                    :flavor_id => ami_type,
                                                    :groups => security_groups,
                                                    :availability_zone => availability_zone,
                                                    :key_name => env.key_name)
        instance_id = response.id
        return instance_id
      end

      def create_spot_instance_request(spot_price, ami, ami_type, security_groups, availability_zone)
        response = @compute_provider.spot_requests.create(:spot_price => spot_price,
                                                          :image_id => ami,
                                                          :flavor_id => ami_type,
                                                          :groups => security_groups,
                                                          :availability_zone => availability_zone,
                                                          :key_name => env.key_name)
        request_id = response.id
        return request_id
      end

      def describe_instances(instance_id=nil)
        instances = []
        opts = {}
        opts["instance-id"] = instance_id if instance_id

        response = @compute_provider.servers.all(opts)
        response.each do |item|
          instance = {}
          instance[:id] = item.id
          instance[:type] = item.flavor_id
          instance[:external_host] = item.dns_name
          instance[:external_ip] = item.public_ip_address
          instance[:internal_host] = item.private_dns_name
          instance[:internal_ip] = item.private_ip_address
          instance[:state] = item.state
          instance[:zone] = item.availability_zone
          instance[:platform] = item.platform || 'linux'
          instance[:root_device_type] = item.root_device_type
          instances << instance
        end

        return instances
      end

      def describe_spot_instance_requests(request_id=nil)
        requests = []
        opts = {}
        opts["spot-instance-request-id"] = request_id if request_id
        response = @compute_provider.spot_requests.all(opts)
        response.each do |item|
          request = {}
          request[:id] = item.id
          request[:spot_price] = item.price
          request[:state] = item.state
          request[:created_at] = item.created_at
          request[:type] = item.flavor_id
          request[:image_id] = item.image_id
          request[:instance_id] = item.instance_id
          requests << request
        end
        return requests
      end


      def destroy_instance(instance_id)
        response = @compute_provider.servers.get(instance_id).destroy()
      end

      def destroy_spot_instance_request(request_id)
        @compute_provider.spot_requests.get(request_id).destroy
      end
  
      def reboot_instance(instance_id)
        response = @compute_provider.servers.get(instance_id).reboot()
      end

      def stop_instance(instance_id, force=false)
        # Don't force the stop process. I.e., allow the instance to flush its file system operations.
        response = @compute_provider.servers.get(instance_id).stop(force)
      end

      def start_instance(instance_id)
        response = @compute_provider.servers.get(instance_id).start()
      end

      def describe_availability_zones
        zones = []
        response = @compute_provider.describe_availability_zones()
        items = response.body["availabilityZoneInfo"] 
        items.each do |item|
          zone = {}
          zone[:name] = item["zoneName"]
          zone[:state] =item["zoneState"]
          zones << zone
        end
        return zones
      end

      def create_security_group(group_name, group_description)
        @compute_provider.security_groups.create(:name => group_name, :description => group_description)
      end

      def describe_security_groups(group_name=nil)
        groups = []

        opts = {}
        opts["group-name"] = group_name if group_name
        response = @compute_provider.security_groups.all(opts)

        response.each do |item|
          group = {}
          group[:name] = item.name
          group[:description] = item.description

          item.ip_permissions.each do |ip_item|
            group[:permissions] ||= []
            rule = {}

            rule[:protocol] = ip_item["ipProtocol"]
            rule[:from_port] = ip_item["fromPort"]
            rule[:to_port] = ip_item["toPort"]

            ip_item["groups"].each do |rule_group|
              rule[:source_groups] ||= []
              source_group = {}
              source_group[:account] = rule_group["userId"]
              source_group[:name] = rule_group["groupName"]
              rule[:source_groups] << source_group
            end if ip_item["groups"]

            ip_item["ipRanges"].each do |ip_range|
              rule[:source_ips] ||= []
              rule[:source_ips] << ip_range["cidrIp"]
            end if ip_item["ipRanges"]

            group[:permissions] << rule
          end

          groups << group
          
        end

        return groups
      end

      def add_security_group_rule(group_name, protocol, from_port, to_port, source)
        group = @compute_provider.security_groups.get(group_name)
        if source.instance_of? Hash
          group.authorize_group_and_owner(source[:name], source[:account])
        else
          group.authorize_port_range(from_port.to_i..to_port.to_i, :ip_protocol => protocol, :cidr_ip => source)
        end
      end

      def remove_security_group_rule(group_name, protocol, from_port, to_port, source)
        group = @compute_provider.security_groups.get(group_name)
        if source.instance_of? Hash
          group.revoke_group_and_owner(source[:name], source[:account])
        else
          group.revoke_port_range(from_port.to_i..to_port.to_i, :ip_protocol => protocol, :cidr_ip => source)
        end
      end

      def destroy_security_group(group_name)
        @compute_provider.security_groups.get(group_name).destroy
      end

      def create_static_ip
        address = @compute_provider.addresses.create()
        return address.public_ip
      end

      def attach_static_ip(ip, instance_id)
        address = @compute_provider.addresses.get(ip)
        server = @compute_provider.servers.get(instance_id)
        response = (address.server = server)
        return ! response.nil?
      end

      def detach_static_ip(ip)
        address = @compute_provider.addresses.get(ip)
        response = (address.server = nil)
        return ! response.nil?
      end

      def describe_static_ips(ip=nil)
        ips = []
        opts = {}
        opts["public-ip"] = ip if ip
        response = @compute_provider.addresses.all(opts)
        response.each do |item|
          ip = {}
          ip[:instance_id] = item.server_id
          ip[:ip] = item.public_ip
          ips << ip
        end
        return ips
      end

      def destroy_static_ip(ip)
        address = @compute_provider.addresses.get(ip)
        return address.destroy
      end

      def create_volume(size, zone)
        volume = @compute_provider.volumes.create(:size => size.to_s, :availability_zone => zone)
        return volume.id
      end

      def attach_volume(volume_id, instance_id, device)
        volume = @compute_provider.volumes.get(volume_id)
        server = @compute_provider.servers.get(instance_id)
        volume.device = device
        volume.server = server
        return volume.status
      end

      def detach_volume(volume_id, force=true)
        volume = @compute_provider.volumes.get(volume_id)
        force ? volume.force_detach : (volume.server = nil)
        return volume.status
      end

      def describe_volumes(volume_id=nil)
        volumes = []
        opts = {}
        opts[:volume-id] = volume_id if volume_id
        response = @compute_provider.volumes.all(opts)
        response.each do |item|
          volume = {}
          volume[:id] = item.id
          volume[:status] = item.state
          if item.server_id
            attach = item.attachmentSet.item[0]
            volume[:attachment_instance_id] = item.server_id
            volume[:attachment_status] = item.attached_at ? "attached" : "waiting"
          end
          volumes << volume
        end
        return volumes
      end

      def destroy_volume(volume_id)
        @compute_provider.volumes.get(volume_id).destroy
      end

      def create_image(image_name)
        ec2_key = env.key_file
        ec2_pk = env.pk_file
        ec2_cert = env.cert_file
        ec2_key_dest = "/mnt/#{File.basename(ec2_key)}"
        ec2_pk_dest = "/mnt/#{File.basename(ec2_pk)}"
        ec2_cert_dest = "/mnt/#{File.basename(ec2_cert)}"

        # validate all needed config set
        ["key_file", "pk_file", "cert_file", "account", "secret_access_key", "image_bucket"].each do |k|
          raise "Set #{k} in rubber.yml" unless "#{env[k]}".strip.size > 0
        end
        raise "create_image can only be called from a capistrano scope" unless capistrano
        
        storage(env.image_bucket).ensure_bucket
        
        capistrano.put(File.read(ec2_key), ec2_key_dest)
        capistrano.put(File.read(ec2_pk), ec2_pk_dest)
        capistrano.put(File.read(ec2_cert), ec2_cert_dest)

        arch = capistrano.capture("uname -m").strip
        arch = case arch when /i\d86/ then "i386" else arch end

        capistrano.sudo_script "create_bundle", <<-CMD
          rvm use system
          export RUBYLIB=/usr/lib/site_ruby/
          unset RUBYOPT
          nohup ec2-bundle-vol --batch -d /mnt -k #{ec2_pk_dest} -c #{ec2_cert_dest} -u #{env.account} -p #{image_name} -r #{arch} &> /tmp/ec2-bundle-vol.log &
          sleep 1

          echo "Creating image from instance volume..."
          while true; do
            if ! ps ax | grep -q "[e]c2-bundle-vol"; then exit; fi
            echo -n .
            sleep 5
          done
        CMD

        capistrano.sudo_script "register_bundle", <<-CMD
          rvm use system
          export RUBYLIB=/usr/lib/site_ruby/
          unset RUBYOPT
          echo "Uploading image to S3..."
          ec2-upload-bundle --batch -b #{env.image_bucket} -m /mnt/#{image_name}.manifest.xml -a #{env.access_key} -s #{env.secret_access_key}
        CMD

        image_location = "#{env.image_bucket}/#{image_name}.manifest.xml"
        response = @ec2.register_image(:image_location => image_location)
        return response.imageId
      end

      def describe_images(image_id=nil)
        images = []
        opts = {"Owner" => "self"}
        opts["image-id"] = image_id if image_id
        response = @compute_provider.images.all(opts)
        response.each do |item|
          image = {}
          image[:id] = item.id
          image[:location] = item.location
          image[:root_device_type] = item.root_device_type
          images << image
        end
        return images
      end

      def destroy_image(image_id)
        image = @compute_provider.images.get(image_id)
        raise "Could not find image: #{image_id}, aborting destroy_image" if image.nil?

        location_parts = image.location.split('/')
        bucket = location_parts.first
        image_name = location_parts.last.gsub(/\.manifest\.xml$/, '')

        image.deregister

        storage(bucket).walk_tree(image_name) do |f|
          f.destroy
        end
      end

      def describe_load_balancers(name=nil)
        lbs = []
        response = name.nil? ? @elb.load_balancers.all() : [@elb.load_balancers.get(name)].compact
        response.each do |item|
          lb = {}
          lb[:name] = item.id
          lb[:dns_name] = item.dns_name
          lb[:zones] = item.availability_zones

          item.listeners.each do |litem|
            listener = {}
            listener[:protocol] = litem.protocol
            listener[:port] = litem.lb_portPort
            listener[:instance_port] = litem.instance_port
            lb[:listeners] ||= []
            lb[:listeners] << listener
          end

          lbs << lb
        end
        return lbs
      end

      # resource_id is any Amazon resource ID (e.g., instance ID or volume ID)
      # tags is a hash of tag_name => tag_value pairs
      def create_tags(resource_id, tags)
        # Tags need to be created individually in fog
        tags.each do |k, v|
          @compute_provider.tags.create(:resource_id => resource_id,
                                        :key => k.to_s, :value => v.to_s)
        end
      end
      
    end

  end
end
