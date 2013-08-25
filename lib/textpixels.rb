require "progress_bar"
require "linguist"
require "pygments"

require_relative "textpixels/version"
require_relative "textpixels/run_state"

class Array
  def each_with_progress
    progress = ProgressBar.new(size)
    each do |item|
      yield item
      progress.increment!
    end
    $stderr.puts # ProgressBar doesn't add a newline when finished
  end

  def top(n)
    self[0, n ? n : size]
  end
end


module TextPixels
  # Parses colors and background-colors out of Pygments styles
  def parse_css(css)
    classes = {}
    css.lines do |line|
      next unless line =~ /^\.(\S+) \{/
      cls = $1
      classes[cls] ||= {}
      classes[cls][:fg] = $1 if line =~ / color: #([\da-f]+)/
      classes[cls][:bg] = $1 if line =~ / background-color: #([\da-f]+)/
    end
    classes
  end

  # Given a pixel as a string (e.g. "ff9900"), return a bytestring (e.g. "\xff\x99\x00")
  def pixel_for(color, alpha)
    @pixel_for ||= {}
    @pixel_for[alpha] ||= {}
    @pixel_for[alpha][color] ||=
      begin
        rgba = color.chars.each_slice(2).map { |hex| hex.join.to_i(16) }
        rgba << 255 if alpha and rgba.size < 4
        rgba.pop if !alpha and rgba.size > 3
        rgba.pack('C*')
      end
  end

  # Convert numeric entities (e.g. "&#39;") to characters, but replace named
  # entities with the Unicode codepoint 0xFFFD REPLACEMENT CHARACTER
  def without_entities(html)
    html.
      gsub(/&#(\d+)/) { |n| [n.to_i].pack('U') }.
      gsub(/&#x([\da-f]+)/i) { |n| [n.to_i(16)].pack('U') }.
      gsub(/&\w+;/, [0xfffd].pack('U'))
  end

  # Pad the list of color pixels to +cols+, using +default_bg+ as filler, if needed
  def padded(colors, cols, default_bg)
    if colors.size < cols
      colors + ([default_bg] * (cols - colors.size))
    else
      colors[0,cols]
    end
  end

  # Given an array of +html+ strings, convert them to rows of pixels of width
  # +cols+, using the provided +css+ classes
  def html_to_pixels(html, css, cols, fg, bg)
    rows = []

    html.each_with_progress do |file|
      colorstack = [ { fg: fg, bg: bg}.merge(css.fetch(lang_css(nil), {})) ]

      file.lines do |line|
        colors = []
        without_entities(line.chomp).split(%r{(<[^>]+>)}).each do |part|
          case part
          when '<pre>'
            # nothing
          when /<(\w+) [^>]*class="([^"]+)">/
            tag, cls = [$1, $2]
            prior = colorstack.last
            newcss = prior.merge(css.fetch(cls, {}))
            colorstack.push(newcss)
            colorstack[0] = newcss if tag == 'div' # div sets defaults
          when %r{</(span|div)}
            colorstack.pop
          else
            part.chars.each do |c|
              colors.push(colorstack.last[c =~ /\S/ ? :fg : :bg])
            end
          end
        end

        next if line == '</pre></div>' # Don't output Pygments per-file footer

        rows << padded(colors, cols, colorstack.first[:bg])
      end
    end
    rows
  end

  # Blit the given +colorrows+ to +out+, optionally using transparency
  def blit(colorrows, opts, out = $stdout)
    out.binmode
    colorrows.each_with_progress do |row|
      row.each do |color|
        out.write(pixel_for(color, opts.alpha?))
      end
    end
  end

  # Use ImageMagick to render the raw pixels
  def magick(colorrows, opts)
    cmd = %w[convert -size]
    cmd << [opts.cols, colorrows.size].join('x')
    cmd += %W[-background ##{opts.bg[0,6]}]
    cmd += %W[-depth 8 #{opts.alpha? ? 'rgba' : 'rgb'}:-]
    if opts.height
      cmd += %W[-crop x#{opts.height} +append]
      if opts.crop
        cmd += %W[-crop #{opts.crop}]
      end
    end
    cmd += [opts.out]
    Open3.popen2(*cmd) do |stdin,stdout|
      stdout.close
      blit(colorrows, opts, stdin)
      stdin.close
    end
  end

  # Get the CSS styles for the chosen Pygments named style
  def colors(opts)
    @colors ||= pygments_css(opts).merge(github_css(opts))
  end

  # Pygments CSS style parsed into fg/bg
  def pygments_css(opts)
    opts.style ? parse_css(Pygments.css(style: opts.style)) : {}
  end

  # Language CSS class for a Linguist::Language
  def lang_css(lang)
    lang ? "lang-#{lang.default_alias_name}" : "lang-unknown"
  end

  # GitHub language colors CSS parsed into fg/bg
  def github_css(opts)
    return {} if opts.lang_as.empty?
    css = class_to_color(opts).flat_map do |cls,color|
      opts.lang_as.map do |prop|
        ".#{cls} { #{prop}: #{color} }"
      end
    end.join("\n")
    parse_css(css)
  end

  # Language CSS class to color mapping
  def class_to_color(opts)
    langs = Hash[Linguist::Language.colors.map { |l| [lang_css(l), l.color] }]
    langs.merge(lang_css(nil) => "##{opts.bg}")
  end

  # Read filenames from STDIN
  def findfiles(state, opts)
    case name = opts.files_from
    when String
      if Dir.exists?(name)
        rel = name
        git = File.join(rel, '.git')
        git = rel unless Dir.exists?(git)
        state.filenames = Open3.popen2(*%Q{git --git-dir=#{git} ls-files}) do |i,o|
          i.close
          o.readlines.map { |f| File.join(rel, f.chomp) }.select do |file|
            File.file?(file)
          end.map { |f| [f, rel] }
        end
      else
        state.filenames = File.read_lines(name)
      end
    when Enumerable
      state.filenames = ARGF.each_line.map(&:chomp)
    end
  end

  # Process files with Linguist, removing binary and generated files
  def identify(state)
    state.filenames.each_with_progress do |file|
      blob = Linguist::FileBlob.new(*file)
      next if blob.binary? or blob.generated? or blob.vendored?
      state.blobs << blob
    end
  end

  def main(opts, phases)
    abort "Bad finish phase" if opts.finish and not phases.include?(opts.finish)

    state = opts.loadstate ? Marshal.load(File.read(opts.loadstate)) : RunState.new
        
    phases.each do |phase|
      if state.ran.include?(phase)
        warn "Already ran #{phase}"
        next
      end

      warn "Running #{phase} phase"
      case phase
      when 'findfiles'
        findfiles(state, opts)
      when 'identify'
        identify(state)
      when 'htmlize'
        state.blobs.each_with_progress do |blob|
          state.html << blob.colorize(options: { cssclass: lang_css(blob.language) })
        end
      when 'pixelate'
        state.colorrows = html_to_pixels(state.html, colors(opts), opts.cols, opts.fg, opts.bg)
      when 'blit'
        blit(state.colorrows.top(opts.linelimit), opts)
      when 'magick'
        magick(state.colorrows.top(opts.linelimit), opts)
      else
        abort "Unknown phase: #{phase}"
      end

      state.ran << phase
      break if opts.finish and phase == opts.finish
    end

    if opts.savestate
      File.open(opts.savestate, 'wb') { |f| f.write(Marshal.dump(state)) }
    end
  end
end

