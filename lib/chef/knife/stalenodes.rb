# Author:: Paul Mooring <paul@opscode.com>
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module KnifeStalenodes
  class Stalenodes < Chef::Knife
    banner 'knife stalenodes [options]'

    # Do lazy load this stuff
    deps do
      require 'highline'
      require 'chef/search/query'
    end

    option :reverse,
           short:       '-r',
           long:        '--reverse',
           description: 'Reverses the search to return only nodes that have checked in recently',
           boolean:     true

    option :days,
           short:       '-D DAYS',
           long:        '--days DAYS',
           description: 'The days since last check in',
           default:     0

    option :hours,
           short:       '-H HOURS',
           long:        '--hours HOURS',
           description: 'Adds hours to days since last check in',
           default:     1

    option :minutes,
           short:       '-m MINUTES',
           long:        '--minutes MINUTES',
           description: 'Adds minutes to hours since last check in',
           default:     0

    option :maxhost,
           short:       '-n HOSTS',
           long:        '--number HOSTS',
           description: 'Max number of hosts to search',
           default:     2500

    option :use_ec2,
           short:       '-e',
           long:        '--use-ec2',
           description: 'Indicate whether or not stale nodes are present in ec2',
           default:     false,
           proc: (
             proc do |key|
               Chef::Config[:knife][:stalenodes] ||= {}
               Chef::Config[:knife][:stalenodes][:use_ec2] = key
             end
           )

    def max_age_secs
      @max_age_secs ||= begin
        seconds = config[:days].to_i * 86_400 +
                  config[:hours].to_i * 3_600 +
                  config[:minutes].to_i * 60

        Time.now.to_i - seconds
      end
    end

    def query_string
      return "ohai_time:[#{max_age_secs} TO *]" if config[:reverse]
      "ohai_time:[* TO #{max_age_secs}]"
    end

    def time_since_last_chef_run(time)
      diff = Time.now.to_i - time
      minutes = (diff / 60)
      days = (minutes / 60 / 24)

      case
      when diff < 3600
        {
          color: :green,
          text: "#{minutes} minute#{minutes == 1 ? ' ' : 's'}"
        }
      when diff > 86_400
        {
          color: :red,
          text: "#{days} day#{days == 1 ? ' ' : 's'}"
        }
      else
        {
          color: :yellow,
          text: "#{minutes / 60} hours"
        }
      end
    end

    def use_ec2?
      Chef::Config[:knife][:stalenodes] &&
        Chef::Config[:knife][:stalenodes][:use_ec2]
    end

    def run
      if use_ec2?
        live_hosts = connection.servers.select do |s|
          s.state == 'running' && s.tags['Name']
        end.map { |s| s.tags['Name'] }
      end

      query = Chef::Search::Query.new
      search_args = {
        filter_result: {
          ohai_time: ['ohai_time'],
          name: ['name']
        },
        rows: config[:maxhost]
      }

      query.search(:node, query_string, search_args).first.each do |node|
        msg = time_since_last_chef_run(node['ohai_time'].to_i)

        if use_ec2?
          islive = live_hosts.include?(node['name']) ? '' : ' - NOT IN EC2'
        end

        output = "#{@ui.color(msg[:text], msg[:color])} ago: #{node['name']}"

        if use_ec2?
          HighLine.new.say output + islive
        else
          HighLine.new.say output
        end
      end
    end

    private

    def connection
      @connection ||= begin
        require 'fog'
        Fog::Compute.new(
          provider: 'AWS',
          aws_access_key_id: Chef::Config[:knife][:aws_access_key_id],
          aws_secret_access_key: Chef::Config[:knife][:aws_secret_access_key],
          region: Chef::Config[:knife][:region]
        )
      end
    end
  end
end
