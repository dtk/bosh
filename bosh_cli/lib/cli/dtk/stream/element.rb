module Bosh::Cli
  module Dtk
    class Element

      include BoshExtensions

      NO_RESULT   = 'no-results'
      TASK_START  = 'task_start'
      TASK_END    = 'task_end'
      STAGE_END   = 'stage_end'
      STAGE_START = 'stage_start'
      TIME_FORMAT = "%H:%M:%S %d/%m/%Y"

      def initialize(hash_content)
        @type = hash_content['type']
        @subtasks = nil

        if is_render?
          @display_name = hash_content['display_name']
          @started_at   = hash_content['started_at']
          @ended_at     = hash_content['ended_at']
          @status       = hash_content['status']
          @position     = hash_content['position']
          @duration     = hash_content['duration']
          @subtasks     = hash_content['subtasks']
        end
      end

      def is_render?
        !NO_RESULT.eql?(@type)
      end

      def is_finished?
        TASK_END.eql?(@type)
      end

      def is_increment?
        [TASK_START, STAGE_END].include?(@type)
      end

      def next_step
        case @type
          when TASK_START
            return :start
          when STAGE_START
            return :end
          when STAGE_END
            return :start
        end

        nil
      end

      def display_name
        @display_name
      end

      def render
        return unless is_render?

        case @type
          when TASK_START
            say("")
            print_line
            say("START TASK :: #{display_name} ::".make_green)
            print_line
            return
          when STAGE_START
            say("STAGE #{@position}: ".make_yellow + display_name.make_green)
            print_line
            say("")
            say("  start time:".make_yellow + " #{started_at}")
            components, action_name, action_results = extract_components_action_name_action_results

            unless components.empty?
              say("  components: ".make_yellow)
              components.each { |cmp| say("    #{cmp}") }
            end

            if action_name
              say("  action: ".make_yellow + action_name)
            end

            if action_results
              render_action_results(action_results)
            end

            return
          when STAGE_END
            say("  status:".make_yellow + " #{@status}")
            say("  end time:".make_yellow + " #{ended_at}")
            say("  duration:".make_yellow + " #{duration}")
            say("")
            print_line
            return
          when TASK_END
            say("END TASK :: #{display_name} :: (total duration: #{duration})".make_green)
            print_line
            return
          end
      end

      def extract_components_action_name_action_results
        components  = []
        action_name = nil
        action_results = nil

        if @subtasks
          @subtasks.each do |task|
            node_name   = node_name(task['node'])
            action_name = action_name(task['action'], node_name)
            action_results ||= task['action_results']
            components << (task['components']||[]).collect { |cmp| "#{node_name}/#{cmp['name']}"}
          end
        end

        [components.flatten, action_name, action_results]
      end

    private

      def render_action_results(arr_element)
        return if arr_element.nil?
        say("  results:".make_yellow)
        arr_element.each do |el|
          say("    command:".make_yellow + " #{el['description']} (exit status: #{el['status']})")
          say("    output:".make_yellow)
          if 0 == el['status']
            say("      #{el['stdout']}")
          else
            say("      #{el['stderr']}".make_red)
          end
        end
      end

      def started_at
        return if @started_at.nil?
        Time.parse(@started_at).strftime(TIME_FORMAT)
      end

      def ended_at
        return if @ended_at.nil?
        Time.parse(@ended_at).strftime(TIME_FORMAT)
      end

      def duration
        return if @duration.nil?
        "#{Float(@duration).round(2)}s"
      end

      def node_name(hash_element)
        'group'.eql?(hash_element['type']) ? "node-group:#{hash_element['name']}" : hash_element['name']
      end

      def action_name(hash_element, node)
        return nil unless hash_element
        "#{node}:#{hash_element['component_name']}.#{hash_element['method_name']}"
      end

      def print_line
        say('-----------------------------------')
      end

    end
  end
end