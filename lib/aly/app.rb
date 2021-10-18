require 'json'
require 'terminal-table'

class Array
  def table
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
      end

      if query = args.first
        selected = selected.select do |item|
          item.values_at('InstanceId', 'InstanceName', 'PrivateIP', 'PublicIP').compact.any? { |e| e.include?(query) }
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
            PublicIP: row['PublicIP']
          }
        end
        puts selected.table.to_s
      end
    end

    def eip(*args, **options)
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

      if query = args.first
        selected = selected.select do |lb|
          lb.values_at('LoadBalancerId', 'LoadBalancerName', 'Address').compact.any? { |e| e.include?(query) }
        end
      end

      if options['detail']
        selected.each do |row|
          described_load_balancer_attributes = exec('slb', 'DescribeLoadBalancerAttribute', "--LoadBalancerId=#{row['LoadBalancerId']}")
          row['BackendServers'] = described_load_balancer_attributes['BackendServers']['BackendServer']
        end

        puts JSON.pretty_generate(selected)
      else
        selected = selected.map do |row|
          listeners = (row['Listeners'] || []).map do |listener|
            listener_port = listener['ListenerPort']
            backend_port = listener['BackendServerPort']
            if backend_port
              "#{listener_port}:#{backend_port}"
            else forward_port = listener.dig('HTTPListenerConfig', 'ForwardPort')
              "#{listener_port}->#{forward_port}"
            end
          end.compact.join(', ')

          {
            Id: row['LoadBalancerId'],
            Name: row['LoadBalancerName'],
            Address: row['Address'],
            Listeners: listeners
          }
        end
        puts selected.table.to_s
      end
    end

    def exec(command, sub_command, *args)
      JSON.parse(`aliyun #{command} #{sub_command} #{args.join(' ')}`)
    end
  end
end
