module TextPixels
  class RunState
    attr_accessor :filenames, :blobs, :html, :colorrows, :ran
    def initialize
      self.filenames = []
      self.blobs = []
      self.html = []
      self.colorrows = []
      self.ran = []
    end
  end
end