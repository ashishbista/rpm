# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/parameter_filtering'

module NewRelic
  module Agent
    module Instrumentation
      module GrapeInstrumentation
        extend self

        API_ENDPOINT   = 'api.endpoint'.freeze
        API_VERSION    = 'api.version'.freeze
        FORMAT_REGEX   = /\(\/?\.[\:\w]*\)/.freeze # either :format (< 0.12.0) or .ext (>= 0.12.0)
        VERSION_REGEX  = /:version(\/|$)/.freeze
        EMPTY_STRING   = ''.freeze
        MIN_VERSION    = Gem::Version.new("0.2.0")
        PIPE_STRING    = '|'.freeze

        def handle_transaction(endpoint, class_name, version)
          return unless endpoint && route = endpoint.route
          name_transaction(route, class_name, version)
          capture_params(endpoint)
        end

        def name_transaction(route, class_name, version)
          txn_name = name_for_transaction(route, class_name, version)
          node_name = "Middleware/Grape/#{class_name}/call"
          Transaction.set_default_transaction_name(txn_name, :grape, node_name)
        end

        def name_for_transaction(route, class_name, version)
          action_name = route.path.sub(FORMAT_REGEX, EMPTY_STRING)
          method_name = route.request_method
          version ||= route.version

          # defaulting does not set rack.env['api.version'] and route.version may return Array
          #
          version = version.join(PIPE_STRING) if Array === version

          if version
            action_name = action_name.sub(VERSION_REGEX, EMPTY_STRING)
            "#{class_name}-#{version}#{action_name} (#{method_name})"
          else
            "#{class_name}#{action_name} (#{method_name})"
          end
        end

        def name_for_transaction_deprecated(route, class_name, version)
          action_name = route.route_path.sub(FORMAT_REGEX, EMPTY_STRING)
          method_name = route.route_method
          version ||= route.route_version

          if version
            action_name = action_name.sub(VERSION_REGEX, EMPTY_STRING)
            "#{class_name}-#{version}#{action_name} (#{method_name})"
          else
            "#{class_name}#{action_name} (#{method_name})"
          end
        end

        def capture_params(endpoint)
          txn = Transaction.tl_current
          env = endpoint.request.env
          params = ParameterFiltering::apply_filters(env, endpoint.params)
          params.delete("route_info")
          txn.filtered_params = params
          txn.merge_request_parameters(params)
        end
      end
    end
  end
end

DependencyDetection.defer do
  # Why not just :grape? newrelic-grape used that name already, and while we're
  # not shipping yet, overloading the name interferes with the plugin.
  named :grape_instrumentation

  depends_on do
    ::NewRelic::Agent.config[:disable_grape] == false
  end

  depends_on do
    defined?(::Grape::VERSION) &&
      Gem::Version.new(::Grape::VERSION) >= ::NewRelic::Agent::Instrumentation::GrapeInstrumentation::MIN_VERSION
  end

  depends_on do
    begin
      if defined?(Bundler) && Bundler.rubygems.all_specs.map(&:name).include?("newrelic-grape")
        ::NewRelic::Agent.logger.info("Not installing New Relic supported Grape instrumentation because the third party newrelic-grape gem is present")
        false
      else
        true
      end
    rescue => e
      ::NewRelic::Agent.logger.info("Could not determine if third party newrelic-grape gem is installed", e)
      true
    end
  end

  executes do
    NewRelic::Agent.logger.info 'Installing New Relic supported Grape instrumentation'
    instrument_call
  end

  def instrument_call
    if defined?(Grape::VERSION) && Gem::Version.new(::Grape::VERSION) >= Gem::Version.new("0.16.0")
      ::NewRelic::Agent::Instrumentation::GrapeInstrumentation.send :remove_method, :name_for_transaction_deprecated
    else
      ::NewRelic::Agent::Instrumentation::GrapeInstrumentation.send :remove_method, :name_for_transaction
      ::NewRelic::Agent::Instrumentation::GrapeInstrumentation.send :alias_method, :name_for_transaction, :name_for_transaction_deprecated
    end

    # Since 1.2.0, the class `Grape::API` no longer refers to an API instance, rather, what used to be `Grape::API` is `Grape::API::Instance`
    # https://github.com/ruby-grape/grape/blob/c20a73ac1e3f3ba1082005ed61bf69452373ba87/UPGRADING.md#upgrading-to--120
    grape_api_class = if defined?(Grape::API::Instance)
                        ::Grape::API::Instance
                      else
                        ::Grape::API
                      end

    grape_api_class.class_eval do
      def call_with_new_relic(env)
        begin
          response = call_without_new_relic(env)
        ensure
          begin
            endpoint = env[::NewRelic::Agent::Instrumentation::GrapeInstrumentation::API_ENDPOINT]
            version = env[::NewRelic::Agent::Instrumentation::GrapeInstrumentation::API_VERSION]

            # Since 1.2.0, how to obtain the class name is changed.
            class_name = self.class.respond_to?(:base) ? self.class.base.name : self.class.name
            ::NewRelic::Agent::Instrumentation::GrapeInstrumentation.handle_transaction(endpoint, class_name, version)
          rescue => e
            ::NewRelic::Agent.logger.warn("Error in Grape instrumentation", e)
          end
        end

        response
      end

      alias_method :call_without_new_relic, :call
      alias_method :call, :call_with_new_relic
    end
  end
end
