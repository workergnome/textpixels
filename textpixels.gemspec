# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'textpixels/version'

Gem::Specification.new do |spec|
  spec.name          = "textpixels"
  spec.version       = TextPixels::VERSION
  spec.authors       = ["Ben Haskell"]
  spec.email         = ["benizi@benizi.com"]
  spec.description   = %q{Generate an image of a repository, visualized as 1-pixel tall text.}
  spec.summary       = %q{Generate an image of a repository, visualized as 1-pixel tall text.}
  spec.homepage      = "https://github.com/benizi/textpixels"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.files.reject! { |fn| fn.include? ".png" }
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]
  
  spec.required_ruby_version = '>= 2.0.0'
  spec.requirements << 'ImageMagick, if you want images instead of raw pixels.'
  spec.requirements << 'Python Pygments `pygmentize` command in your PATH.'
  
  spec.add_dependency "github-linguist",  '~> 2.9'
  spec.add_dependency "progress_bar", "~> 1.0"
  spec.add_dependency "pygments.rb", "~> 0.5" 
  
  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  
end
