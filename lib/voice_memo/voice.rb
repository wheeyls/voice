# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'net/http'
require 'uri'
require 'time'
require 'openai'

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

      # Check if audio file was created successfully
      unless File.exist?(@audio_file) && File.size(@audio_file) > 1000
        puts "Error: Audio recording failed or file is too small."
        log("Audio recording failed or file is too small: #{@audio_file}")
        return
      end

      transcribe_audio

      if File.exist?(@transcript_file)
        content = File.read(@transcript_file)

        # Check if the content indicates an error
        if content.start_with?('Error:')
          puts "Transcription error occurred:"
          puts '-------------------------------'
          puts content
          puts '-------------------------------'
          puts "Check logs in #{@logs_dir} for details"
          cleanup
          return
        end

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
        cleanup
        puts 'Voice memo processed successfully!'
      else
        puts 'Transcription failed.'
        log("Transcription file not created: #{@transcript_file}")
        cleanup
      end
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

      # Check for ruby-openai gem
      begin
        require 'openai'
      rescue LoadError
        missing_deps << 'ruby-openai (Ruby gem for OpenAI API)'
      end

      # Check for OpenAI API key
      if ENV['OPENAI_API_KEY'].nil? || ENV['OPENAI_API_KEY'].empty?
        missing_deps << 'OPENAI_API_KEY environment variable'
      end

      # Check for editor
      editor = ENV['EDITOR'] || 'nano'
      missing_deps << "#{editor} (for editing transcriptions)" unless command_exists?(editor)

      return unless missing_deps.any?

      puts 'Error: The following dependencies are missing:'
      missing_deps.each { |dep| puts "  - #{dep}" }
      puts "\nPlease install the missing dependencies and try again."
      puts 'For sox: brew install sox'
      puts 'For ruby-openai: gem install ruby-openai'
      puts 'For OpenAI API key: export OPENAI_API_KEY=your-api-key'
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

      # Use specific format that OpenAI accepts: 16kHz sample rate, mono, 16-bit PCM WAV
      # This is important as OpenAI has specific format requirements
      pid = spawn("rec -r 16000 -c 1 -b 16 -e signed-integer #{@audio_file} trim 0 silence 1 0.1 1% 2>> #{@log_file}")

      log("Recording process started with PID: #{pid}")

      # Wait for Enter key
      $stdin.gets

      # Record for at least 1 second to avoid empty files
      sleep 0.5

      # Stop recording - use SIGINT (Ctrl+C) which is more reliable for terminating sox
      begin
        log("Stopping recording process (PID: #{pid})")
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
          log("Process still running, sending TERM signal")
          Process.kill('TERM', pid)
          sleep 0.5
          # If still running after TERM, use KILL as last resort
          begin
            Process.kill(0, pid)
            log("Process still running after TERM, sending KILL signal")
            # If still running after TERM, use KILL as last resort
            Process.kill('KILL', pid)
          rescue StandardError
            # Process already terminated
            log("Process already terminated")
          end
        end
      ensure
        # Wait for the process to fully terminate
        begin
          Process.wait(pid)
          log("Recording process terminated")
        rescue StandardError => e
          log("Error waiting for process: #{e.message}")
          nil
        end

        # Double check if any sox/rec processes are still running for this file
        cleanup_cmd = "pkill -f 'rec.*#{File.basename(@audio_file)}' 2>/dev/null || true"
        system(cleanup_cmd)
      end

      puts 'Recording stopped.'

      # Verify the audio file was created properly
      if File.exist?(@audio_file)
        file_size = File.size(@audio_file)
        log("Audio file created: #{@audio_file}, size: #{file_size} bytes")

        if file_size < 1000
          log("Warning: Audio file is very small (#{file_size} bytes), may not contain speech")
        end
      else
        log("Error: Audio file was not created")
        puts "Error: Failed to create audio recording."
      end
    end

    def transcribe_audio
      puts 'Transcribing audio with OpenAI Whisper API...'
      log("Starting transcription for #{@audio_file}")

      # Check if audio file has content
      if !File.exist?(@audio_file)
        puts 'Error: Audio file does not exist.'
        File.write(@transcript_file, 'Error: Audio file does not exist.')
        return
      end

      file_size = File.size(@audio_file)
      log("Audio file size: #{file_size} bytes")

      if file_size < 1000
        puts 'Warning: Audio file is too small. No speech was likely detected.'
        File.write(@transcript_file, 'No speech detected. Please try recording again with clearer audio.')
        return
      end

      # Check if file is too large (OpenAI has a 25MB limit)
      if file_size > 25 * 1024 * 1024
        puts 'Error: Audio file exceeds the 25MB size limit for OpenAI API.'
        File.write(@transcript_file, 'Error: Audio file exceeds the 25MB size limit for OpenAI API.')
        return
      end

      begin
        # Log file details
        log("Audio file details: #{@audio_file}")
        log("File exists: #{File.exist?(@audio_file)}")
        log("File size: #{File.size(@audio_file)} bytes")
        log("File readable: #{File.readable?(@audio_file)}")

        # Initialize OpenAI client
        client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])

        # Verify the file can be opened
        audio_file = File.open(@audio_file, "rb")
        log("File opened successfully")

        # Transcribe the audio file
        puts 'Sending audio to OpenAI for transcription...'
        log("Sending request to OpenAI API with file: #{@audio_file}")

        # Add response_format parameter to ensure we get text back
        response = client.audio.transcribe(
          parameters: {
            model: "whisper-1",
            file: audio_file,
            language: "en",
            response_format: "json"
          }
        )

        log('OpenAI transcription completed')
        log("Response: #{response.inspect}")

        # Extract the transcription text
        transcription = response["text"]

        if transcription && !transcription.empty?
          puts 'Transcription received successfully.'
          log("Transcription text: #{transcription[0..100]}...")
          File.write(@transcript_file, transcription)
        else
          puts 'Warning: Could not extract transcription text'
          log("Empty transcription received: #{response.inspect}")
          File.write(@transcript_file, 'No speech detected. Please try recording again with clearer audio.')
        end
      rescue StandardError => e
        puts "Error during transcription: #{e.message}"
        log("Transcription error: #{e.message}")
        log(e.backtrace.join("\n"))

        # Provide more helpful error messages based on common issues
        error_message = case e.message
                        when /status 400/
                          "The API rejected the request. This could be due to an invalid audio format, " +
                          "corrupted audio file, or unsupported audio codec. Try recording again."
                        when /status 401/
                          "Authentication error. Please check your OpenAI API key."
                        when /status 429/
                          "Rate limit exceeded. Please try again later."
                        when /status 5\d\d/
                          "OpenAI server error. Please try again later."
                        else
                          "Error during transcription: #{e.message}"
                        end

        puts error_message
        File.write(@transcript_file, error_message)

        # Don't exit the program on error, just return
        return
      ensure
        # Make sure we close the file handle if it was opened
        audio_file.close if defined?(audio_file) && !audio_file.nil? && !audio_file.closed?
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

      # Create messages array
      messages = [
        {
          role: 'system',
          content: system_prompt
        },
        {
          role: 'user',
          content: "Please reformat the following text into a #{tone} tone, preserving all the key information: #{content}"
        }
      ]

      # Log the request payload
      log('API Request Messages:')
      log(JSON.pretty_generate(messages))

      begin
        # Initialize OpenAI client
        client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])

        # Make the API request
        response = client.chat(
          parameters: {
            model: 'gpt-4o',
            messages: messages,
            temperature: 0.7
          }
        )

        # Log the response
        log('API Response:')
        log(JSON.pretty_generate(response))

        # Extract the formatted content
        if response['choices'] && response['choices'][0] && response['choices'][0]['message']
          return response['choices'][0]['message']['content']
        end

        puts 'Error: Unexpected response structure from OpenAI API'
        log("Unexpected response structure: #{response.inspect}")
        nil
      rescue StandardError => e
        puts "Error calling OpenAI API: #{e.message}"
        log("API Error: #{e.message}")
        log(e.backtrace.join("\n"))
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
