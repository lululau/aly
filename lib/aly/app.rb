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
      each { |row| t << (row.nil? ? :separator : row.values) }
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

    def full_slb(lbs, eips, **options)
      lbs.each do |lb|
        puts "\nLoanBalancer Id: %s, Name: %s" % [lb['LoadBalancerId'], lb['LoadBalancerName']]
        puts "==============================================================\n\n"
        listeners = lb['Listeners']
        background_servers = exec('slb', 'DescribeLoadBalancerAttribute', "--LoadBalancerId=#{lb['LoadBalancerId']}", **options)['BackendServers']['BackendServer'] || []

        puts '    LoadBalancer Basic Information:'
        puts([{
                Id: lb['LoadBalancerId'],
                Name: lb['LoadBalancerName'],
                Address: lb['Address'],
                Eip: lb['Eip'],
                Listeners: listeners.size
              }].table.to_s.gsub(/^/, '    '))
        puts

        if background_servers && background_servers.size > 0
          puts '    Default Backend Servers:'
          puts

          ecss = @ecs.select { |e| background_servers.map{|ee| ee['ServerId']}.include?(e['InstanceId']) }

          puts ecss.map { |row|
            {
              Id: row['InstanceId'],
              Name: row['InstanceName'],
              PrivateIP: row['PrivateIP'].join(','),
              PublicIP: row['PublicIP'].join(','),
              CPU: row['Cpu'],
              RAM: "#{row['Memory'] / 1024.0} GB"
            }
          }.table.to_s.gsub(/^/, '    ')
          puts
        end

        vserver_groups = exec('slb', 'DescribeVServerGroups', '--pager', "--LoadBalancerId=#{lb['LoadBalancerId']}", **options)["VServerGroups"]["VServerGroup"] || []
        vserver_group_servers = vserver_groups.flat_map do |vg|
          vg_attr = exec('slb', 'DescribeVServerGroupAttribute', "--VServerGroupId=#{vg['VServerGroupId']}", **options)["BackendServers"]["BackendServer"]
          vg_attr.each_with_index.map do |attr, idx|
            ecs = @ecs.find {|e| e['InstanceId'] == attr['ServerId'] }
            {
              VGroupId: (idx.zero? ? vg['VServerGroupId'] : ''),
              VGroupName: (idx.zero? ? vg['VServerGroupName'] : ''),
              Weight: attr['Weight'],
              Port: attr['Port'],
              Type: attr['Type'],
              EcsId: attr['ServerId'],
              EcsName: ecs['InstanceName'],
              PrivateIP: ecs['PrivateIP'].join(','),
              PublicIP: ecs['PublicIP'].join(','),
              CPU: ecs['Cpu'],
              RAM: "#{ecs['Memory'] / 1024.0} GB"
            }
          end + [nil]
        end
        puts '    VServer Groups:'
        puts vserver_group_servers[0..-2].table.to_s.gsub(/^/, '    ')
        puts

        listeners.each do |listener|
          listener_type = ['HTTP', 'HTTPS', 'TCP', 'TCPS', 'UDP'].find { |e| !listener["#{e}ListenerConfig"].empty? }
          listener['ListenerType'] = listener_type
        end

        listeners_info = listeners.map do |listener|
          {
            Description: listener['Description'],
            Port: listener['ListenerPort'],
            Protocol: listener['ListenerProtocol'],
            Status: listener['Status'],
            HeathCheck: (listener["#{listener['ListenerType']}ListenerConfig"] || {}).dig("HealthCheck") || 'off',
            BackendServerPort: listener['BackendServerPort'],
            ForwardPort: listener.dig('HTTPListenerConfig', 'ForwardPort'),
            VServerGroup: listener['VServerGroupId'],
            AclStatus: listener['AclStatus'] || 'off',
            AclType: listener['AclType'],
            AclIds: (listener['AclIds'] || []).join(','),
          }
        end

        puts '    Configured Listeners:'
        puts listeners_info.table.to_s.gsub(/^/, '    ')
        puts

        listener_rules = listeners.flat_map do |listener|
          listener_type = listener['ListenerType']
          next [] unless listener_type
          rules = exec('slb', "DescribeLoadBalancer#{listener_type}ListenerAttribute", "--LoadBalancerId=#{lb['LoadBalancerId']}", "--ListenerPort=#{listener['ListenerPort']}", **options).dig('Rules', 'Rule') || []
          rules.map do |rule|
            {'Listener' => listener['Description']}.merge(rule)
          end
        end

        puts '    Listener Rules:'
        puts listener_rules.table.to_s.gsub(/^/, '    ')
        puts

        if options['acl']
          acl_ids = listeners.flat_map { |listener| listener['AclIds'] || [] }.uniq
          unless acl_ids.empty?
            alc_entries = acl_ids.flat_map do |acl_id|
              attr = exec('slb', 'DescribeAccessControlListAttribute', "--AclId=#{acl_id}", **options)
              (attr.dig('AclEntrys', 'AclEntry') || []).each_with_index.map do |e, idx|
                {
                  AclId: (idx.zero? ? attr['AclId'] : ''),
                  AclName: (idx.zero? ? attr['AclName'] : ''),
                  AclEntryIP: e['AclEntryIP'],
                  AclEntryComment: e['AclEntryComment']
                }
              end + [nil]
            end
            puts '    Access Control Lists:'
            puts alc_entries[0..-2].table.to_s.gsub(/^/, '    ')
            puts
          end

        end

      end
    end

    def slb(*args, **options)
      raw_out = exec('slb', 'DescribeLoadBalancers', '--pager', **options)
      selected = raw_out['LoadBalancers']['LoadBalancer'] || []

      eips = exec('vpc', 'DescribeEipAddresses', "--PageSize=#{selected.size}", **options)['EipAddresses']['EipAddress'].each_with_object({}) do |item, result|
        result[item['InstanceId']] = item['IpAddress']
      end

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

      @eip ||= exec('vpc', 'DescribeEipAddresses', '--PageSize=100', **options)['EipAddresses']['EipAddress'] || []

      eip_map = @eip.each_with_object({}) { |eip, h| h[eip['InstanceId']] = eip['IpAddress'] }
      selected.each do |slb|
        slb['Eip'] = eip_map[slb['LoadBalancerId']]
      end

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

      if options['full']
        full_slb(selected, eips, **options)
      elsif options['detail']
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
            Eip: eips[row['LoadBalancerId']] || '',
            Listeners: listeners
          }
        end
        puts selected.table&.to_s
      end
    end

    def slb_contains_host?(host)
      @slb.any? { |lb| lb['Address'] == host || lb['Eip'] == host }
    end

    def ecs_contains_host?(host)
      @ecs.any? { |item| item['AllIPs'].include?(host) }
    end

    def show_slb(host, **options)
      @listeners ||= exec('slb', 'DescribeLoadBalancerListeners', '--pager', 'path=Listeners', **options)['Listeners'] || []
      lb = @slb.find { |e| e['Address'] == host || e['Eip'] == host }
      listeners = @listeners.select { |e| e['LoadBalancerId'] == lb['LoadBalancerId'] }

      puts "\nLoanBalancer Id: %s, Name: %s" % [lb['LoadBalancerId'], lb['LoadBalancerName']]
      puts "==============================================================\n\n"
      background_servers = exec('slb', 'DescribeLoadBalancerAttribute', "--LoadBalancerId=#{lb['LoadBalancerId']}", **options)['BackendServers']['BackendServer'] || []

      puts '    LoadBalancer Basic Information:'
      puts([{
              Id: lb['LoadBalancerId'],
              Name: lb['LoadBalancerName'],
              Address: lb['Address'],
              Eip: lb['Eip'],
              Listeners: listeners.size
            }].table.to_s.gsub(/^/, '    '))
      puts

      if background_servers && background_servers.size > 0
        puts '    Default Backend Servers:'
        puts

        ecss = @ecs.select { |e| background_servers.map{|ee| ee['ServerId']}.include?(e['InstanceId']) }

        puts ecss.map { |row|
          {
            Id: row['InstanceId'],
            Name: row['InstanceName'],
            PrivateIP: row['PrivateIP'].join(','),
            PublicIP: row['PublicIP'].join(','),
            CPU: row['Cpu'],
            RAM: "#{row['Memory'] / 1024.0} GB"
          }
        }.table.to_s.gsub(/^/, '    ')
        puts
      end

      vserver_groups = exec('slb', 'DescribeVServerGroups', '--pager', "--LoadBalancerId=#{lb['LoadBalancerId']}", **options)["VServerGroups"]["VServerGroup"] || []
      vserver_group_servers = vserver_groups.flat_map do |vg|
        vg_attr = exec('slb', 'DescribeVServerGroupAttribute', "--VServerGroupId=#{vg['VServerGroupId']}", **options)["BackendServers"]["BackendServer"]
        vg_attr.each_with_index.map do |attr, idx|
          ecs = @ecs.find {|e| e['InstanceId'] == attr['ServerId'] }
          {
            VGroupId: (idx.zero? ? vg['VServerGroupId'] : ''),
            VGroupName: (idx.zero? ? vg['VServerGroupName'] : ''),
            Weight: attr['Weight'],
            Port: attr['Port'],
            Type: attr['Type'],
            EcsId: attr['ServerId'],
            EcsName: ecs['InstanceName'],
            PrivateIP: ecs['PrivateIP'].join(','),
            PublicIP: ecs['PublicIP'].join(','),
            CPU: ecs['Cpu'],
            RAM: "#{ecs['Memory'] / 1024.0} GB"
          }
        end + [nil]
      end
      puts '    VServer Groups:'
      puts vserver_group_servers[0..-2].table.to_s.gsub(/^/, '    ')
      puts

      listeners.each do |listener|
        listener_type = ['HTTP', 'HTTPS', 'TCP', 'TCPS', 'UDP'].find { |e| !listener["#{e}ListenerConfig"].empty? }
        listener['ListenerType'] = listener_type
      end

      listeners_info = listeners.map do |listener|
        {
          Description: listener['Description'],
          Port: listener['ListenerPort'],
          Protocol: listener['ListenerProtocol'],
          Status: listener['Status'],
          HeathCheck: (listener["#{listener['ListenerType']}ListenerConfig"] || {}).dig("HealthCheck") || 'off',
          BackendServerPort: listener['BackendServerPort'],
          ForwardPort: listener.dig('HTTPListenerConfig', 'ForwardPort'),
          VServerGroup: listener['VServerGroupId'],
          AclStatus: listener['AclStatus'] || 'off',
          AclType: listener['AclType'],
          AclIds: (listener['AclIds'] || []).join(','),
        }
      end

      puts '    Configured Listeners:'
      puts listeners_info.table.to_s.gsub(/^/, '    ')
      puts

      listener_rules = listeners.flat_map do |listener|
        listener_type = listener['ListenerType']
        next [] unless listener_type
        rules = exec('slb', "DescribeLoadBalancer#{listener_type}ListenerAttribute", "--LoadBalancerId=#{lb['LoadBalancerId']}", "--ListenerPort=#{listener['ListenerPort']}", **options).dig('Rules', 'Rule') || []
        rules.map do |rule|
          {'Listener' => listener['Description']}.merge(rule)
        end
      end

      puts '    Listener Rules:'
      puts listener_rules.table.to_s.gsub(/^/, '    ')
      puts

      if options['acl']
        acl_ids = listeners.flat_map { |listener| listener['AclIds'] || [] }.uniq
        unless acl_ids.empty?
          alc_entries = acl_ids.flat_map do |acl_id|
            attr = exec('slb', 'DescribeAccessControlListAttribute', "--AclId=#{acl_id}", **options)
            (attr.dig('AclEntrys', 'AclEntry') || []).each_with_index.map do |e, idx|
              {
                AclId: (idx.zero? ? attr['AclId'] : ''),
                AclName: (idx.zero? ? attr['AclName'] : ''),
                AclEntryIP: e['AclEntryIP'],
                AclEntryComment: e['AclEntryComment']
              }
            end + [nil]
          end
          puts '    Access Control Lists:'
          puts alc_entries[0..-2].table.to_s.gsub(/^/, '    ')
          puts
        end

      end
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

      eip_map = @eip.each_with_object({}) { |eip, h| h[eip['InstanceId']] = eip['IpAddress'] }
      @slb.each do |slb|
        slb['Eip'] = eip_map[slb['LoadBalancerId']]
      end

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
        eip(host, **options)
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
