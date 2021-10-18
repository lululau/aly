require 'thor'

module Aly
  class CLI < ::Thor
    class_option :profile, type: :string, optional: true, aliases: ['-p'], desc: 'select profile'
    class_option :detail, type: :boolean, optional: true, default: false, aliases: ['-d'], desc: 'show detail infomation in JSON format'

    desc 'eip', 'get EIP information'
    def eip(query = nil)
      App.new.start(options: options, command: :eip, args: [query])
    end

    desc 'slb', 'get SLB information'
    def slb(query = nil)
      App.new.start(options: options, command: :slb, args: [query])
    end

    class << self
      def main(args)
        start(args)
      end
    end
  end
end
