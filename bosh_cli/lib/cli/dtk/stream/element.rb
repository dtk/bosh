module Bosh::Cli
  module Dtk
    class Element

      include BoshExtensions

      NO_RESULT   = 'no-results'
      TASK_START  = 'task_start'
      TASK_END    = 'task_end'
      STAGE_END   = 'stage_end'
      STAGE_START = 'stage_start'
      STAGE       = 'stage'

      def initialize(hash_content)
        @type = hash_content['type']

        if is_render?
          @display_name = hash_content['display_name']
          @started_at   = hash_content['started_at']
          @ended_at     = hash_content['ended_at']
          @status       = hash_content['status']
          @position     = hash_content['position']
          @duration     = hash_content['duration']
        end
      end

      def is_render?
        !NO_RESULT.eql?(@type)
      end

      def is_finished?
        TASK_END.eql?(@type)
      end

      def is_increment?
        [TASK_START, STAGE_END, STAGE].include?(@type)
      end

      def display_name
        @display_name
      end

      def render
        return unless is_render?

        case @type
          when TASK_START
            say("-> Start task #{display_name}".make_green)
            return
          when STAGE_START
            print_line
            say("STAGE #{position}: #{display_name}")
            say("TIME: #{@started_at}")
            return
          when STAGE_END, STAGE
            print_line
            say("STATUS: #{@status}")
            say("DURATION: #{@duration}")
            return
          when TASK_END
            say("-> End task #{display_name} (total duration: #{@duration})".make_green)
            return
          end
      end

    private

      def print_line
        say('---------------------------------------------------------------------------------')
      end

    end
  end
end