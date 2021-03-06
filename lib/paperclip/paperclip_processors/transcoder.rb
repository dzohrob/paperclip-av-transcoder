module Paperclip
  class Transcoder < Processor
    attr_accessor :geometry, :format, :whiny, :convert_options
    # Creates a Video object set to work on the +file+ given. It
    # will attempt to transcode the video into one defined by +target_geometry+
    # which is a "WxH"-style string. +format+ should be specified.
    # Video transcoding will raise no errors unless
    # +whiny+ is true (which it is, by default. If +convert_options+ is
    # set, the options will be appended to the convert command upon video transcoding.
    def initialize file, options = {}, attachment = nil
      log "Options: #{options.to_s}"
      log "Attachment: #{attachment.inspect}"

      @file             = file
      @current_format   = File.extname(@file.path)
      @basename         = File.basename(@file.path, @current_format)
      @cli              = ::Av.cli
      @style            = options[:style] || 'default'
      @meta             = ::Av.cli.identify(@file.path)
      @whiny            = options[:whiny].nil? ? true : options[:whiny]

      @convert_options  = set_convert_options(options)

      @format           = options[:format]

      @geometry         = options[:geometry]
      unless @geometry.nil?
        modifier = @geometry[0]
        @geometry[0] = '' if ['#', '<', '>'].include? modifier
        @width, @height   = @geometry.split('x')
        @keep_aspect      = @width[0] == '!' || @height[0] == '!'
        @pad_only         = @keep_aspect    && modifier == '#'
        @enlarge_only     = @keep_aspect    && modifier == '<'
        @shrink_only      = @keep_aspect    && modifier == '>'
      end

      @exif_data = MiniExiftool.new(@file.path)
      @meta[:rotate] = @exif_data.rotation
      log "Rotation data: #{@meta[:rotate]}"

      @time             = options[:time].nil? ? 3 : options[:time]
      @auto_rotate      = options[:auto_rotate].nil? ? false : options[:auto_rotate]
      @pad_color        = options[:pad_color].nil? ? "black" : options[:pad_color]

      @convert_options[:output][:s] = format_geometry(@geometry) if @geometry.present?

      @attachment = attachment
    end

    # Performs the transcoding of the +file+ into a thumbnail/video. Returns the Tempfile
    # that contains the new image/video.
    def make
      ::Av.logger = Paperclip.logger
      @cli.add_source @file
      dst = Tempfile.new([@basename, @format ? ".#{@format}" : ''])
      dst.binmode

      if @meta
        log "Transcoding supported file #{@file.path}"
        @cli.add_source(@file.path)
        @cli.add_destination(dst.path)
        @cli.reset_input_filters

        if output_is_image?
          @time = @time.call(@meta, @options) if @time.respond_to?(:call)
          @cli.filter_seek @time
        end

        # if @auto_rotate && !@meta[:rotate].nil?
        #   log "Adding rotation #{@meta[:rotate]}"
        #   arg = case @meta[:rotate]
        #         when 90 then 'transpose=1'
        #         when 180 then 'vflip, hflip'
        #         when 270 then 'transpose=2'
        #         end
        #   if arg
        #     if @convert_options[:output][:vf]
        #       @convert_options[:output][:vf] += ", #{arg}"
        #     else
        #       @convert_options[:output][:vf] = "#{arg}"
        #     end
        #   end
        #   @convert_options[:output][:vf] = "'#{@convert_options[:output][:vf]}'"
        # end

        if @convert_options.present?
          if @convert_options[:input]
            @convert_options[:input].each do |h|
              @cli.add_input_param h
            end
          end
          if @convert_options[:output]
            @convert_options[:output].each do |h|
              @cli.add_output_param h
            end
          end
        end

        begin
          @cli.run
          log "Successfully transcoded #{@basename} to #{dst}"

          exif_data = MiniExiftool.new(dst.path)
          log "Exif data: #{exif_data.inspect}"
          @meta[:output] ||= {}
          # set metadata correctly if image is rotated
          if exif_data.rotatation == 90 || exif_data.rotation == 270
            @meta[:output][:width] = exif_data.imageheight
            @meta[:output][:height] = exif_data.imagewidth
          else
            @meta[:output][:width] = exif_data.imagewidth
            @meta[:output][:height] = exif_data.imageheight
          end

        rescue Cocaine::ExitStatusError => e
          raise Paperclip::Error, "error while transcoding #{@basename}: #{e}" if @whiny
        end
      else
        log "Unsupported file #{@file.path}"
        # If the file is not supported, just return it
        dst << @file.read
        dst.close
      end

      # todo: maybe clean this up? attachment model can handle the read/write
      # of metadata.
      if @attachment
        @attachment_meta = @attachment.meta || {}
        @attachment_meta[@style.to_sym] = @meta
        json_meta = JSON.dump(@attachment_meta)
        log "JSON metadata: #{json_meta}"
        @attachment.instance_write(:meta, json_meta)
      end

      dst
    end

    def log message
      Paperclip.log "[transcoder] #{message}"
    end

    def set_convert_options options
      return options[:convert_options] if options[:convert_options].present?
      options[:convert_options] = {output: {}}
      return options[:convert_options]
    end

    def format_geometry geometry
      return unless geometry.present?
      return geometry.gsub(/[#!<>)]/, '')
    end

    def output_is_image?
      !!@format.to_s.match(/jpe?g|png|gif$/)
    end
  end

  class Attachment
    def meta
      data = instance_read(:meta)
      data ? JSON.load(instance_read(:meta)) : nil
    end
  end
end
