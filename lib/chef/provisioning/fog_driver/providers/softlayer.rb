require 'base64'
require 'uri'

# fog:SoftLayer:<datacenter>
class Chef
  module Provisioning
    module FogDriver
      module Providers
        class SoftLayer < FogDriver::Driver
          Driver.register_provider_class('SoftLayer', FogDriver::Providers::SoftLayer)

          def creator
            compute_options[:softlayer_username]
          end

          def self.compute_options_for(provider, id, config)
            new_compute_options = {}
            new_compute_options[:provider] = provider
            new_config = { :driver_options => { :compute_options => new_compute_options }}
            new_defaults = {
              :driver_options => { :compute_options => {} },
              :machine_options => { :bootstrap_options => {} }
            }
            result = Cheffish::MergedConfig.new(new_config, config, new_defaults)
            new_defaults[:machine_options][:bootstrap_options][:datacenter] = id if (id && id != '')

            credential = Fog.credentials

            new_compute_options[:softlayer_username] ||= credential[:softlayer_username]
            new_compute_options[:softlayer_api_key] ||= credential[:softlayer_api_key]

            id = result[:driver_options][:compute_options][:softlayer_auth_url]

            [result, id]
          end

          def bootstrap_options_for(action_handler, machine_spec, machine_options)
            opts = super
            if opts[:bare_metal]
              #these don't work with fog-softlayer bare_metal for some reason...
              opts.delete :key_name
              opts.delete :tags
            end

            opts
          end

          def find_floating_ips(server, action_handler)
            []
          end

          def create_servers(action_handler, specs_and_options, parallelizer, &block)
              super do |machine_spec, server|
                  userData = server.service.request( :virtual_guest, server.id, :query => {:objectMask => 'userData'}).body['userData']
                  no_user_data = userData.nil? || userData.empty?
                  if no_user_data
                    creds = Fog.credentials
                    ::Retryable.retryable(:tries => 60, :sleep => 2) do
                      sleep(2)

                      res = server.service.request :virtual_guest, "#{server.id}/setUserMetadata", :http_method => 'POST', :body => [
                        [
                          Base64.encode64(
                            URI::HTTPS.build(
                              :userinfo => "#{creds[:softlayer_username]}:#{creds[:softlayer_api_key]}",
                              :host => 'api.service.softlayer.com',
                              :path => "/rest/v3/SoftLayer_Virtual_Guest/#{server.id}/setUserMetadata",
                            ).to_s
                          )
                        ]
                      ]

                      raise "Failed to setUserMetadata" unless TrueClass == res.body.class
                    end
                  end

                  block.call(machine_spec, server) if block
              end
          end

          def wait_until_ready(action_handler, machine_spec, machine_options, server)
            super

            action_handler.report_progress "waiting for post-install script on #{server.name} to finish"

            ::Retryable.retryable(:tries => 60, :sleep => 2) do
                action_handler.report_progress "checking post-install status on #{server.name}"
                res = server.service.request(:virtual_guest, server.id, :query => 'objectMask=userData')
                userData = res.body['userData']
                value = userData.first['value']

                raise "Waiting for post-install script" unless "post-script-done" == value
            end

            action_handler.report_progress "post-install done on #{server.name}"
          end

          def start_server(action_handler, machine_spec, server)
              ::Retryable.retryable(:tries => 10, :sleep => 2) do
                  super
              end
          end
        end
      end
    end
  end
end

