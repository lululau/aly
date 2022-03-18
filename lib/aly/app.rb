require 'json'
require 'terminal-table'
require 'socket'


class Array
  def table
    return if size.zero?
    header = first.keys
    Terminal::Table.new { |t|
      t << header
      t << :separator
      each { |row| t << row.values }
    }
  end
end

module Aly
  class App
    def start(options)
      send(options[:command], *options[:args], **options[:options])
    end

    def ecs(*args, **options)
      raw_out = exec('ecs', 'DescribeInstances', '--pager', **options)
      selected = (raw_out['Instances']['Instance'] || []).each do |item|
        item['PrivateIP'] = (item['NetworkInterfaces']['NetworkInterface'] || []).map { |ni| ni['PrimaryIpAddress'] }.join(',')
        item['PublicIP'] = item['EipAddress']['IpAddress'] || ''
        item['PublicIP'] = item['PublicIpAddress']['IpAddress'].join(',') if item['PublicIP'] == ''
      end

      if query = args.first&.split(',')
        selected = selected.select do |item|
          item.values_at('InstanceId', 'InstanceName', 'PrivateIP', 'PublicIP').compact.any? { |e| query.any? { |q| e.include?(q) } }
        end
      end

      if options['detail']
        puts JSON.pretty_generate(selected)
      else
        selected = selected.map do |row|
          {
            Id: row['InstanceId'],
            Name: row['InstanceName'],
            PrivateIP: row['PrivateIP'],
            PublicIP: row['PublicIP'],
            CPU: row['Cpu'],
            RAM: "#{row['Memory'] / 1024.0} GB"
          }
        end
        puts selected.table&.to_s
      end
    end

    def eip(*args, **options)
      puts 'EIPs:'
      raw_out = exec('vpc', 'DescribeEipAddresses', '--PageSize=100', **options)
      selected = raw_out['EipAddresses']['EipAddress']

      if query = args.first&.split(',')
        selected = selected.select do |item|
          item.values_at('AllocationId', 'InstanceId', 'InstanceType', 'IpAddress').compact.any? { |e| query.any? { |q| e.include?(q) } }
        end
      end

      if options['detail']
        puts JSON.pretty_generate(selected)
      else
        net_intefraces = exec('ecs', 'DescribeNetworkInterfaces', '--pager', **options)['NetworkInterfaceSets']['NetworkInterfaceSet'].each_with_object({}) do |item, result|
          result[item['NetworkInterfaceId']] = item
        end
        selected = selected.map do |row|
          result = {
            Id: row['AllocationId'],
            InstanceId: row['InstanceId'],
            InstanceType: row['InstanceType'],
            IP: row['IpAddress'],
            EcsId: '',
            PrivateIP: ''
          }

          if row['InstanceType'] == 'NetworkInterface' && interface = net_intefraces[row['InstanceId']]
            result[:EcsId] = interface['InstanceId']
            result[:PrivateIP] = interface['PrivateIpAddress']
          end

          result
        end
        puts selected.table&.to_s
      end
    end

    def slb(*args, **options)
      raw_out = exec('slb', 'DescribeLoadBalancers', '--pager', **options)
      selected = raw_out['LoadBalancers']['LoadBalancer'] || []

      listeners = (exec('slb', 'DescribeLoadBalancerListeners', '--pager', 'path=Listeners', **options)['Listeners'] || []).each_with_object({}) do |listener, result|
        instance_id = listener['LoadBalancerId']
        result[instance_id] ||= []
        result[instance_id] << listener
      end

      selected.each do |lb|
        lb['Listeners'] = listeners[lb['LoadBalancerId']] || []
      end

      if query = args.first&.split(',')
        selected = selected.select do |lb|
          lb.values_at('LoadBalancerId', 'LoadBalancerName', 'Address').compact.any? { |e| query.any? { |q| e.include?(q) } }
        end
      end

      if options['detail']
        selected.each do |row|
          described_load_balancer_attributes = exec('slb', 'DescribeLoadBalancerAttribute', "--LoadBalancerId=#{row['LoadBalancerId']}", **options)
          row['BackendServers'] = described_load_balancer_attributes['BackendServers']['BackendServer']

          row['Listeners'].select { |e| e['VServerGroupId'] }.each do |listener|
            vserver_group = exec('slb', 'DescribeVServerGroupAttribute', "--VServerGroupId=#{listener['VServerGroupId']}", **options)
            listener['VServerGroup'] = vserver_group
          end
        end

        puts JSON.pretty_generate(selected)
      else
        selected = selected.map do |row|
          listeners = (row['Listeners'] || []).map do |listener|
            listener_port = listener['ListenerPort']
            backend_port = listener['BackendServerPort']
            if backend_port
              "#{listener_port}:#{backend_port}"
            elsif forward_port = listener.dig('HTTPListenerConfig', 'ForwardPort')
              "#{listener_port}->#{forward_port}"
            elsif vserver_group_id = listener['VServerGroupId']
              "#{listener_port}->#{vserver_group_id}"
            end
          end.compact.join(', ')

          {
            Id: row['LoadBalancerId'],
            Name: row['LoadBalancerName'],
            Address: row['Address'],
            Listeners: listeners
          }
        end
        puts selected.table&.to_s
      end
    end

    def slb_contains_host?(host)
      @slb.any? { |lb| lb['Address'] == host }
    end

    def ecs_contains_host?(host)
      @ecs.any? { |item| item['AllIPs'].include?(host) }
    end

    def show_slb(host, **options)
      @listeners ||= exec('slb', 'DescribeLoadBalancerListeners', '--pager', 'path=Listeners', **options)['Listeners'] || []
      lb = @slb.find { |e| e['Address'] == host }
      listeners = @listeners.select { |e| e['LoadBalancerId'] == lb['LoadBalancerId'] }
      background_servers = exec('slb', 'DescribeLoadBalancerAttribute', "--LoadBalancerId=#{lb['LoadBalancerId']}", **options)['BackendServers']['BackendServer']

      puts 'LoadBalancers:'
      puts([{
        Id: lb['LoadBalancerId'],
        Name: lb['LoadBalancerName'],
        Address: lb['Address'],
        Listeners: listeners.size
      }].table.to_s)
      puts

      if background_servers && background_servers.size > 0
        puts 'Default Backend Servers:'
        puts background_servers.table.to_s
        puts
      end

      listeners_info = listeners.map do |listener|
        {
          Port: listener['ListenerPort'],
          Protocol: listener['ListenerProtocol'],
          Status: listener['Status'],
          BackendServerPort: listener['BackendServerPort'],
          ForwardPort: listener.dig('HTTPListenerConfig', 'ForwardPort'),
          VServerGroup: listener['VServerGroupId']
        }
      end

      puts 'Configured Listeners:'
      puts listeners_info.table.to_s
      puts

      listeners_info.each do |listener|
        if listener[:VServerGroup]
          vserver_group = exec('slb', 'DescribeVServerGroupAttribute', "--VServerGroupId=#{listener[:VServerGroup]}", **options)["BackendServers"]["BackendServer"]
          puts "VServerGroup #{listener[:VServerGroup]}:"
          puts(vserver_group.map { |e|
            {
              EcsInstanceId: e['ServerId'],
              Port: e['Port'],
              Weight: e['Weight'],
              Type: e['Type']
            }
          }.table.to_s)
          puts
        end
      end

      ecs_ids = background_servers.map { |e| e['ServerId'] }
      ecs_ids += listeners_info.flat_map { |e|
        if e[:VServerGroup]
          exec('slb', 'DescribeVServerGroupAttribute', "--VServerGroupId=#{e[:VServerGroup]}", **options)["BackendServers"]["BackendServer"].map { |e| e['ServerId'] }
        else
          []
        end
      }
      ecs_ids.uniq!

      ecss = @ecs.select { |e| ecs_ids.include?(e['InstanceId']) }

      puts "Referenced ECS Instances:"

      puts ecss.map { |row|
        {
          Id: row['InstanceId'],
          Name: row['InstanceName'],
          PrivateIP: row['PrivateIP'].join(','),
          PublicIP: row['PublicIP'].join(','),
          CPU: row['Cpu'],
          RAM: "#{row['Memory'] / 1024.0} GB"
        }
      }.table.to_s

    end

    def show_ecs(host)
      selected = @ecs.select { |e| e['AllIPs'].include?(host) }.map do |row|
        {
          Id: row['InstanceId'],
          Name: row['InstanceName'],
          PrivateIP: row['PrivateIP'].join(','),
          PublicIP: row['PublicIP'].join(','),
          CPU: row['Cpu'],
          RAM: "#{row['Memory'] / 1024.0} GB"
        }
      end
      puts 'ECS Instances:'
      puts selected.table&.to_s
    end

    def eip_contains_host?(host)
      @eip.any? { |eip| eip['IpAddress'] == host }
    end

    def show(*args, **options)
      @slb ||= exec('slb', 'DescribeLoadBalancers', '--pager', **options)['LoadBalancers']['LoadBalancer'] || []

      @eip ||= exec('vpc', 'DescribeEipAddresses', '--PageSize=100', **options)['EipAddresses']['EipAddress'] || []
      unless @ecs
        @ecs = exec('ecs', 'DescribeInstances', '--pager', **options)['Instances']['Instance'] || []
        @ecs.each do |item|
          item['PrivateIP'] = (item['NetworkInterfaces']['NetworkInterface'] || []).map { |ni| ni['PrimaryIpAddress'] }
          item['PublicIP'] = []
          if ip = item['EipAddress']['IpAddress']
            item['PublicIP'] << ip
          end
          if ips = item['PublicIpAddress']['IpAddress']
            item['PublicIP'] += ips
          end
          item['AllIPs'] = item['PrivateIP'] + item['PublicIP']
        end
      end

      host = IPSocket::getaddress(args.first)

      puts "Host: #{args.first} resolves to #{host}" if host != args.first
      puts

      if slb_contains_host?(host)
        show_slb(host, **options)
      elsif ecs_contains_host?(host)
        show_ecs(host)
      elsif eip_contains_host?(host)
        eip(host)
      else
        puts "Not found: #{host}"
      end
    end

    def exec(command, sub_command, *args, **options)
      command = "aliyun #{command} #{sub_command} #{args.join(' ')}"
      command += " -p #{options['profile']}" if options['profile']
      JSON.parse(`#{command}`)
    end
  end
end
