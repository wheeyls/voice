# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'net/http'
require 'uri'
require 'time'

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
      create_default_prompt_file
      record_audio
      transcribe_audio

      if File.exist?(@transcript_file)
        content = File.read(@transcript_file)
        final_content = content

        if @tone
          formatted_content = apply_tone(content, @tone)

          if formatted_content
            File.write(@formatted_file, formatted_content)
            final_content = formatted_content

            puts "Original Transcription:"
            puts "-------------------------------"
            puts content
            puts "-------------------------------"

            puts "Formatted with #{@tone} tone:"
            puts "-------------------------------"
            puts formatted_content
            puts "-------------------------------"

            puts "Saved formatted memo to #{@formatted_file}"

            copy_to_clipboard(formatted_content)
          else
            puts "Warning: Tone formatting failed, using original transcription"
            puts "Check logs in #{@logs_dir} for details"

            puts "Transcription:"
            puts "-------------------------------"
            puts content
            puts "-------------------------------"

            copy_to_clipboard(content)
          end
        else
          puts "Transcription:"
          puts "-------------------------------"
          puts content
          puts "-------------------------------"

          copy_to_clipboard(content)
        end

        puts "Saved voice memo to #{@transcript_file}"
      else
        puts "Transcription failed."
        exit 1
      end

      cleanup
      puts "Voice memo processed successfully!"
    end

    private

    def parse_args(args)
      tone = nil

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: voice [options]"

        opts.on("--tone TONE", "Apply a specific tone to the transcription") do |t|
          tone = t
        end

        opts.on_tail("-h", "--help", "Show this message") do
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
      missing_deps << "sox (for audio recording)" unless command_exists?('rec')

      # Check for ffmpeg (required by whisper)
      missing_deps << "ffmpeg (required for audio processing)" unless command_exists?('ffmpeg')

      # Check for whisper
      unless command_exists?('whisper')
        whisper_path = File.join(ENV['HOME'], '.asdf/installs/python/3.9.9/bin/whisper')
        if File.executable?(whisper_path)
          ENV['PATH'] = "#{File.dirname(whisper_path)}:#{ENV['PATH']}"
        else
          missing_deps << "whisper (OpenAI's transcription tool)"
        end
      end

      # Check for curl (for OpenAI API calls)
      missing_deps << "curl (for API calls)" unless command_exists?('curl')

      if missing_deps.any?
        puts "Error: The following dependencies are missing:"
        missing_deps.each { |dep| puts "  - #{dep}" }
        puts "\nPlease install the missing dependencies and try again."
        puts "For sox: brew install sox"
        puts "For ffmpeg: brew install ffmpeg"
        puts "For whisper: pip install -U openai-whisper"
        exit 1
      end
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

    def create_default_prompt_file
      prompt_file = File.join(ENV['HOME'], '.voice-default-prompt')

      unless File.exist?(prompt_file)
        puts "Creating default prompt file at #{prompt_file}"
        File.write(prompt_file, <<~PROMPT)
          You are a dictation assistant for Mike Wheeler, a CTO of G2.com. Mike is a busy executive who is still an individual contributor, and actively coding on a daily basis. He is a web developer first, and a CTO second. He is a product engineer that focuses on highly integrated teams building early business solutions. You will be used to take dictation for voice messages, emails, articles and announcements, as well as technical specifications and note keeping.
        PROMPT
        puts "Default prompt file created. You can edit it at #{prompt_file}"
      end
    end

    def record_audio
      log("Starting audio recording for #{@audio_file}")

      puts "Recording... Press Enter to stop."

      # Start recording in a separate process
      pid = spawn("rec -r 48000 -c 1 #{@audio_file} trim 0 silence 1 0.1 1% 2>> #{@log_file}")

      # Wait for Enter key
      $stdin.gets

      # Stop recording
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil

      puts "Recording stopped."
    end

    def transcribe_audio
      puts "Transcribing audio with Whisper..."
      log("Starting transcription for #{@audio_file}")

      # Run whisper command
      output, status = Open3.capture2e(
        "whisper",
        @audio_file,
        "--model", "base",
        "--output_dir", @tmp_dir,
        "--output_format", "txt"
      )

      log("Whisper exit status: #{status.exitstatus}")
      log("Full Whisper Output:")
      log(output)

      if status.success?
        # Extract transcription from whisper output
        transcription = extract_transcription(output)

        if transcription && !transcription.empty?
          File.write(@transcript_file, transcription)
        else
          puts "Warning: Could not extract transcription text"
          File.write(@transcript_file, output)
          puts "Full whisper output saved to #{@transcript_file} for debugging"
        end
      else
        puts "Error: Whisper command failed with status #{status.exitstatus}"
        exit 1
      end
    end

    def extract_transcription(output)
      # Extract lines with timestamps and combine them
      lines = output.lines.grep(/^\[.*-->.*\]/)

      if lines.empty?
        return nil
      end

      # Process each line to remove timestamps
      text = lines.map do |line|
        line.gsub(/\[.*-->.*\]/, '').strip
      end.join(' ')

      text.strip
    end

    def apply_tone(content, tone)
      log("Starting tone application (#{tone}) for content")

      # Check if OPENAI_API_KEY is set
      unless ENV['OPENAI_API_KEY']
        puts "Error: OPENAI_API_KEY environment variable is not set"
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
        model: "gpt-4o",
        messages: [
          {
            role: "system",
            content: system_prompt
          },
          {
            role: "user",
            content: "Please reformat the following text into a #{tone} tone, preserving all the key information: #{content}"
          }
        ],
        temperature: 0.7
      }

      # Log the request payload
      log("API Request Payload:")
      log(JSON.pretty_generate(payload))

      # Make the API request
      uri = URI.parse("https://api.openai.com/v1/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
      request.body = payload.to_json

      response = http.request(request)

      # Log the response
      log("API Response Status: #{response.code}")
      log("API Response Body:")
      log(response.body)

      # Print first part of response for debugging
      puts "API Response (first 200 chars):" if ENV['DEBUG']
      puts "#{response.body[0..200]}..." if ENV['DEBUG']

      # Parse the response
      begin
        json_response = JSON.parse(response.body)

        if json_response['error']
          puts "Error from OpenAI API:"
          puts json_response['error']['message']
          return nil
        end

        if json_response['choices'] && json_response['choices'][0] && json_response['choices'][0]['message']
          return json_response['choices'][0]['message']['content']
        else
          puts "Error: Unexpected response structure from OpenAI API"
          return nil
        end
      rescue JSON::ParserError => e
        puts "Error parsing JSON response: #{e.message}"
        log("JSON Parse Error: #{e.message}")
        return nil
      end
    end

    def get_core_prompt
      prompt_file = File.join(ENV['HOME'], '.voice-default-prompt')
      default_prompt = "You are a dictation assistant. You will be used to take dictation for voice messages, emails, articles and announcements, as well as technical specifications and note keeping."

      if File.exist?(prompt_file)
        prompt = File.read(prompt_file).strip
        prompt.empty? ? default_prompt : prompt
      else
        default_prompt
      end
    end

    def copy_to_clipboard(content)
      IO.popen('pbcopy', 'w') { |f| f << content }
      puts "Content copied to clipboard"
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
        if File.file?(file) && (Time.now - File.mtime(file)) > 86400 # 1 day in seconds
          File.unlink(file) rescue nil
        end
      end
    end

    def rotate_log_file
      if File.exist?(@log_file) && File.size(@log_file) > 10_485_760 # 10MB
        timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
        FileUtils.mv(@log_file, File.join(@logs_dir, "voice_#{timestamp}.log"))

        # Keep only the 5 most recent rotated logs
        log_files = Dir.glob(File.join(@logs_dir, 'voice_*.log')).sort_by { |f| File.mtime(f) }.reverse
        log_files[5..-1].each { |f| File.unlink(f) rescue nil } if log_files.size > 5
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
