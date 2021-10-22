require 'json'
require 'terminal-table'

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
      raw_out = exec('ecs', 'DescribeInstances', '--pager')
      selected = raw_out['Instances']['Instance'].each do |item|
        item['PrivateIP'] = (item['NetworkInterfaces']['NetworkInterface'] || []).map { |ni| ni['PrimaryIpAddress'] }.join(', ')
        item['PublicIP'] = item['EipAddress']['IpAddress'] || ''
        item['PublicIP'] = item['PublicIpAddress']['IpAddress'].join(', ') if item['PublicIP'] == ''
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
      raw_out = exec('vpc', 'DescribeEipAddresses', '--PageSize=100')
      selected = raw_out['EipAddresses']['EipAddress']

      if query = args.first&.split(',')
        selected = selected.select do |item|
          item.values_at('AllocationId', 'InstanceId', 'InstanceType', 'IpAddress').compact.any? { |e| query.any? { |q| e.include?(q) } }
        end
      end

      if options['detail']
        puts JSON.pretty_generate(selected)
      else
        net_intefraces = exec('ecs', 'DescribeNetworkInterfaces', '--pager')['NetworkInterfaceSets']['NetworkInterfaceSet'].each_with_object({}) do |item, result|
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
      raw_out = exec('slb', 'DescribeLoadBalancers', '--pager')
      selected = raw_out['LoadBalancers']['LoadBalancer']

      listeners = exec('slb', 'DescribeLoadBalancerListeners', '--pager', 'path=Listeners')['Listeners'].each_with_object({}) do |listener, result|
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
          described_load_balancer_attributes = exec('slb', 'DescribeLoadBalancerAttribute', "--LoadBalancerId=#{row['LoadBalancerId']}")
          row['BackendServers'] = described_load_balancer_attributes['BackendServers']['BackendServer']

          row['Listeners'].select { |e| e['VServerGroupId'] }.each do |listener|
            vserver_group = exec('slb', 'DescribeVServerGroupAttribute', "--VServerGroupId=#{listener['VServerGroupId']}")
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

    def exec(command, sub_command, *args)
      JSON.parse(`aliyun #{command} #{sub_command} #{args.join(' ')}`)
    end
  end
end
