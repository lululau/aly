require 'thor'

module Aly
  class CLI < ::Thor
    class_option :profile, type: :string, optional: true, aliases: ['-p'], desc: 'select profile'
    class_option :detail, type: :boolean, optional: true, default: false, aliases: ['-d'], desc: 'show detail infomation in JSON format'

    desc 'ecs', 'get ECS information'
    def ecs(query = nil)
      App.new.start(options: options, command: :ecs, args: [query])
    end

    desc 'eip', 'get EIP information'
    def eip(query = nil)
      App.new.start(options: options, command: :eip, args: [query])
    end

    desc 'slb', 'get SLB information'
    def slb(query = nil)
      App.new.start(options: options, command: :slb, args: [query])
    end

    desc 'show', 'show resource information of host'
    def show(host = nil)
      App.new.start(options: options, command: :show, args: [host])
    end

    class << self
      def main(args)
        start(args)
      end
    end
  end
end
