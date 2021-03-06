module GraphQL
  module Parallel
    class ExecutionStrategy < GraphQL::Query::BaseExecution
      def initialize
        # Why isn't `require "celluloid/current"` enough here?
        Celluloid.boot unless Celluloid.running?
        @has_futures = false
      end

      def pool
        @pool ||= ExecutionPool.run!
        @pool[:execution_worker_pool]
      end

      def async(block)
        @has_futures ||= true
        pool.future.resolve(block)
      end

      def has_futures?
        @has_futures
      end

      class OperationResolution < GraphQL::Query::SerialExecution::OperationResolution
        def result
          result_futures = super
          if execution_strategy.has_futures?
            finished_result = finish_all_futures(result_futures)
          else
            # Don't bother re-traversing the result if there are no futures.
            finished_result = result_futures
          end
        ensure
          execution_strategy.pool.terminate
          finished_result
        end

        # Recurse over `result_object`, finding any futures and
        # getting their finished values.
        def finish_all_futures(result_object)
          if result_object.is_a?(GraphQL::Parallel::FutureFieldResolution)
            resolved_value = finish_all_futures(result_object.result)
          elsif result_object.is_a?(Hash)
            result_object.each do |key, value|
              result_object[key] = finish_all_futures(value)
            end
            resolved_value = result_object
          elsif result_object.is_a?(Array)
            resolved_value = result_object.map { |v| finish_all_futures(v) }
          else
            resolved_value = result_object
          end
          resolved_value

        end
      end

      class SelectionResolution < GraphQL::Query::SerialExecution::SelectionResolution
      end

      class FieldResolution < GraphQL::Query::SerialExecution::FieldResolution
        def get_finished_value(raw_value)
          if raw_value.is_a?(Celluloid::Future)
            GraphQL::Parallel::FutureFieldResolution.new(field_resolution: self, future: raw_value)
          else
            super
          end
        end
      end

      class InlineFragmentResolution < GraphQL::Query::SerialExecution::InlineFragmentResolution
      end

      class FragmentSpreadResolution < GraphQL::Query::SerialExecution::FragmentSpreadResolution
      end
    end
  end
end
