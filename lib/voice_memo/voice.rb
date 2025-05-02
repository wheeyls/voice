# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'net/http'
require 'uri'
require 'time'
require 'whisper'

module VoiceMemo
  class Voice
    attr_reader :tone, :audio_file, :transcript_file, :formatted_file

    def initialize(args)
      @tone = parse_args(args)
      @timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      @voicememos_dir = File.join(ENV['HOME'], 'voicememos')
      @tmp_dir = File.join(@voicememos_dir, 'tmp')
      @logs_dir = File.join(@voicememos_dir, 'logs')
      @log_file = File.join(@logs_dir, 'voice.log')
      @audio_file = File.join(@tmp_dir, "audio_#{@timestamp}.wav")
      @transcript_file = File.join(@voicememos_dir, "memo_#{@timestamp}.txt")
      @formatted_file = @tone ? File.join(@voicememos_dir, "memo_#{@timestamp}_#{@tone.gsub(/\s+/, '_')}.txt") : nil
    end

    def run
      check_dependencies
      ensure_directories
      record_audio
      transcribe_audio

      if File.exist?(@transcript_file)
        content = File.read(@transcript_file)

        if @tone
          formatted_content = apply_tone(content, @tone)

          if formatted_content
            File.write(@formatted_file, formatted_content)
            final_content = formatted_content

            puts 'Original Transcription:'
            puts '-------------------------------'
            puts content
            puts '-------------------------------'

            puts "Formatted with #{@tone} tone:"
            puts '-------------------------------'
            puts formatted_content
            puts '-------------------------------'

            puts "Saved formatted memo to #{@formatted_file}"

            # Open in editor for final edits
            edited_content = open_in_editor(final_content)
            copy_to_clipboard(edited_content)
          else
            puts 'Warning: Tone formatting failed, using original transcription'
            puts "Check logs in #{@logs_dir} for details"

            puts 'Transcription:'
            puts '-------------------------------'
            puts content
            puts '-------------------------------'

            # Open in editor for final edits
            edited_content = open_in_editor(content)
            copy_to_clipboard(edited_content)
          end
        else
          puts 'Transcription:'
          puts '-------------------------------'
          puts content
          puts '-------------------------------'

          # Open in editor for final edits
          edited_content = open_in_editor(content)
          copy_to_clipboard(edited_content)
        end

        puts "Saved voice memo to #{@transcript_file}"
      else
        puts 'Transcription failed.'
        exit 1
      end

      cleanup
      puts 'Voice memo processed successfully!'
    end

    private

    def parse_args(args)
      tone = nil

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: voice [options]'

        opts.on('--tone TONE', 'Apply a specific tone to the transcription') do |t|
          tone = t
        end

        opts.on_tail('-h', '--help', 'Show this message') do
          puts opts
          exit
        end
      end

      parser.parse!(args)
      tone
    end

    def check_dependencies
      missing_deps = []

      # Check for sox (for recording)
      missing_deps << 'sox (for audio recording)' unless command_exists?('rec')

      # Check for whispercpp gem
      begin
        require 'whisper'
      rescue LoadError
        missing_deps << 'whispercpp (Ruby gem for speech recognition)'
      end

      # Check for curl (for OpenAI API calls)
      missing_deps << 'curl (for API calls)' unless command_exists?('curl')

      # Check for editor
      editor = ENV['EDITOR'] || 'nano'
      missing_deps << "#{editor} (for editing transcriptions)" unless command_exists?(editor)

      return unless missing_deps.any?

      puts 'Error: The following dependencies are missing:'
      missing_deps.each { |dep| puts "  - #{dep}" }
      puts "\nPlease install the missing dependencies and try again."
      puts 'For sox: brew install sox'
      puts 'For whispercpp: gem install whispercpp'
      exit 1
    end

    def command_exists?(command)
      system("which #{command} > /dev/null 2>&1")
    end

    def ensure_directories
      [@voicememos_dir, @tmp_dir, @logs_dir].each do |dir|
        unless Dir.exist?(dir)
          puts "Creating directory at #{dir}"
          FileUtils.mkdir_p(dir)
        end
      end
    end

    def record_audio
      log("Starting audio recording for #{@audio_file}")

      puts 'Recording... Press Enter to stop.'

      # Start recording in a separate process
      pid = spawn("rec -r 48000 -c 1 #{@audio_file} trim 0 silence 1 0.1 1% 2>> #{@log_file}")

      # Wait for Enter key
      $stdin.gets

      # Record for at least 1 second to avoid empty files
      sleep 0.5

      # Stop recording - use SIGINT (Ctrl+C) which is more reliable for terminating sox
      begin
        Process.kill('INT', pid)
        # Give it a moment to clean up
        sleep 0.5
        # Check if process is still running
        process_running = false
        begin
          Process.kill(0, pid)
          process_running = true
        rescue StandardError
          process_running = false
        end

        if process_running
          # If still running, try TERM
          Process.kill('TERM', pid)
          sleep 0.5
          # If still running after TERM, use KILL as last resort
          begin
            Process.kill(0, pid)
            # If still running after TERM, use KILL as last resort
            Process.kill('KILL', pid)
          rescue StandardError
            # Process already terminated
          end
        end
      ensure
        # Wait for the process to fully terminate
        begin
          Process.wait(pid)
        rescue StandardError
          nil
        end

        # Double check if any sox/rec processes are still running for this file
        cleanup_cmd = "pkill -f 'rec.*#{File.basename(@audio_file)}' 2>/dev/null || true"
        system(cleanup_cmd)
      end

      puts 'Recording stopped.'
    end

    def transcribe_audio
      puts 'Transcribing audio with WhisperCPP...'
      log("Starting transcription for #{@audio_file}")

      # Check if audio file has content
      if !File.exist?(@audio_file) || File.size(@audio_file) < 1000
        puts 'Warning: Audio file is empty or too small. No speech was detected.'
        File.write(@transcript_file, 'No speech detected. Please try recording again with clearer audio.')
        return
      end

      begin
        # Initialize whisper context with the base.en model
        whisper = Whisper::Context.new("base.en")

        # Create params with default values first
        params = Whisper::Params.new
        
        # Then set individual parameters
        params.language = "en"
        params.print_timestamps = false
        params.print_progress = true

        # Suppress log output from whisper.cpp
        Whisper.log_set lambda { |level, buffer, _user_data|
          # Only log errors
          log("WhisperCPP Error: #{buffer}") if level == Whisper::LOG_LEVEL_ERROR
        }, nil

        # Transcribe the audio file
        result = whisper.transcribe(@audio_file, params)
        
        # Extract text from the result by iterating through segments
        transcription = ''
        result.each_segment do |segment|
          transcription += segment.text + ' '
        end
        
        transcription = transcription.strip

        log('WhisperCPP transcription completed')

        if transcription && !transcription.empty?
          File.write(@transcript_file, transcription)
        else
          puts 'Warning: Could not extract transcription text'
          File.write(@transcript_file, 'No speech detected. Please try recording again with clearer audio.')
        end
      rescue StandardError => e
        puts "Error during transcription: #{e.message}"
        log("Transcription error: #{e.message}")
        log(e.backtrace.join("\n"))
        File.write(@transcript_file, "Error during transcription: #{e.message}")
        exit 1
      end
    end

    def apply_tone(content, tone)
      log("Starting tone application (#{tone}) for content")

      # Check if OPENAI_API_KEY is set
      unless ENV['OPENAI_API_KEY']
        puts 'Error: OPENAI_API_KEY environment variable is not set'
        puts "Please set it with: export OPENAI_API_KEY='your-api-key'"
        return nil
      end

      # Get core prompt
      core_prompt = get_core_prompt

      # Create system prompt based on tone
      system_prompt = case tone
                      when 'business_casual'
                        "#{core_prompt} You are reformatting text into a business casual tone. Keep the content intact but make it appropriate for professional settings while maintaining a conversational feel."
                      when 'formal'
                        "#{core_prompt} You are reformatting text into a formal tone. Keep the content intact but make it appropriate for formal business or academic settings."
                      when 'email'
                        "#{core_prompt} You are reformatting text into a proper email format. Keep the content intact but structure it as a professional email with greeting and signature."
                      when 'slack'
                        "#{core_prompt} You are reformatting text into a Slack message style. Keep the content intact but make it concise and appropriate for team communication on Slack."
                      when 'direct_message'
                        "#{core_prompt} You are reformatting text into a direct message style. Keep the content intact but make it conversational and appropriate for one-on-one messaging."
                      when 'social_media'
                        "#{core_prompt} You are reformatting text into a social media post style. Keep the content intact but make it engaging and appropriate for social media platforms."
                      when 'article'
                        "#{core_prompt} You are reformatting text into an article style. Keep the content intact but structure it with proper paragraphs, transitions, and a more formal writing style."
                      else
                        "#{core_prompt} You are reformatting text according to this instruction: #{tone}. Keep the content intact but adapt it as specified."
                      end

      # Create API request payload
      payload = {
        model: 'gpt-4o',
        messages: [
          {
            role: 'system',
            content: system_prompt
          },
          {
            role: 'user',
            content: "Please reformat the following text into a #{tone} tone, preserving all the key information: #{content}"
          }
        ],
        temperature: 0.7
      }

      # Log the request payload
      log('API Request Payload:')
      log(JSON.pretty_generate(payload))

      # Make the API request
      uri = URI.parse('https://api.openai.com/v1/chat/completions')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{ENV['OPENAI_API_KEY']}"
      request.body = payload.to_json

      response = http.request(request)

      # Log the response
      log("API Response Status: #{response.code}")
      log('API Response Body:')
      log(response.body)

      # Print first part of response for debugging
      puts 'API Response (first 200 chars):' if ENV['DEBUG']
      puts "#{response.body[0..200]}..." if ENV['DEBUG']

      # Parse the response
      begin
        json_response = JSON.parse(response.body)

        if json_response['error']
          puts 'Error from OpenAI API:'
          puts json_response['error']['message']
          return nil
        end

        if json_response['choices'] && json_response['choices'][0] && json_response['choices'][0]['message']
          return json_response['choices'][0]['message']['content']
        end

        puts 'Error: Unexpected response structure from OpenAI API'
        nil
      rescue JSON::ParserError => e
        puts "Error parsing JSON response: #{e.message}"
        log("JSON Parse Error: #{e.message}")
        nil
      end
    end

    def get_core_prompt
      prompt_file = File.join(ENV['HOME'], '.voice-default-prompt')
      default_prompt = 'You are a dictation assistant. You will be used to take dictation for voice messages, emails, articles and announcements, as well as technical specifications and note keeping.'

      if File.exist?(prompt_file)
        prompt = File.read(prompt_file).strip
        prompt.empty? ? default_prompt : prompt
      else
        default_prompt
      end
    end

    def open_in_editor(content)
      # Create a temporary file for editing
      edit_file = File.join(@tmp_dir, "edit_#{@timestamp}.txt")
      File.write(edit_file, content)

      # Determine which editor to use
      editor = ENV['EDITOR'] || 'nano'

      puts "Opening content in #{editor} for final edits. Save and exit when done."
      log("Opening content in editor: #{editor}")

      # Open the file in the editor
      system("#{editor} #{edit_file}")

      # Read the edited content
      if File.exist?(edit_file)
        edited_content = File.read(edit_file)
        begin
          File.unlink(edit_file)
        rescue StandardError
          nil
        end
        edited_content
      else
        puts 'Warning: Editor did not save the file. Using original content.'
        content
      end
    end

    def copy_to_clipboard(content)
      IO.popen('pbcopy', 'w') { |f| f << content }
      puts 'Content copied to clipboard'
    end

    def cleanup
      # Remove temporary files
      File.unlink(@audio_file) if File.exist?(@audio_file)

      # Clean up whisper output files
      base_name = File.basename(@audio_file, '.wav')
      whisper_txt = File.join(@tmp_dir, "#{base_name}.txt")
      File.unlink(whisper_txt) if File.exist?(whisper_txt)

      # Clean up old temp files (older than 1 day)
      clean_old_files(@tmp_dir)

      # Rotate log file if needed
      rotate_log_file
    end

    def clean_old_files(dir)
      Dir.glob(File.join(dir, '*')).each do |file|
        next unless File.file?(file) && (Time.now - File.mtime(file)) > 86_400

        begin
          File.unlink(file)
        rescue StandardError
          nil
        end
        # 1 day in seconds
      end
    end

    def rotate_log_file
      return unless File.exist?(@log_file) && File.size(@log_file) > 10_485_760 # 10MB

      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      FileUtils.mv(@log_file, File.join(@logs_dir, "voice_#{timestamp}.log"))

      # Keep only the 5 most recent rotated logs
      log_files = Dir.glob(File.join(@logs_dir, 'voice_*.log')).sort_by { |f| File.mtime(f) }.reverse
      return unless log_files.size > 5

      log_files[5..-1].each do |f|
        File.unlink(f)
      rescue StandardError
        nil
      end
    end

    def log(message)
      timestamp = Time.now.strftime('%a %b %d %H:%M:%S %Z %Y')
      File.open(@log_file, 'a') do |f|
        f.puts "#{timestamp}: #{message}"
      end
    end
  end
end
