module Applitools
  module Selenium
    class RegionProvider

      def initialize(driver, eye_region)
        self.driver = driver
        self.eye_region = eye_region
        self.scroll_position_provider = Applitools::Selenium::ScrollPositionProvider.new driver
      end

      def region
        region = Applitools::Region.from_location_size(eye_region.location, eye_region.size)
        if inside_a_frame?
          frame_window = calculate_frame_window
          return frame_window if eye_region.is_a?(Applitools::Region) && eye_region.empty?
          region.location = region.location.offset(frame_window.location)
          region.intersect(frame_window) unless frame_window.empty?
          #exception if empty
        else
          region.location = region.location.offset_negative scroll_position_provider.current_position
        end
        return eye_region if eye_region.is_a?(Applitools::Region) && eye_region.empty?
        region
      end

      def coordinate_type
        nil
      end

      def entire_element_screenshot_offset
        if eye_region.is_a?(Applitools::Region) && eye_region.empty?
          eye_region.location
        else
          region.location
        end
      end

      def viewport_screenshot_offset
        offset = Applitools::Location::TOP_LEFT.dup
        offset.offset scroll_position_provider.current_position
        frame_window = calculate_frame_window
        offset.offset_negative(frame_window.location)
        offset
      end

      private
      attr_accessor :driver, :eye_region, :scroll_position_provider

      def calculate_frame_window
        return Applitools::Region::EMPTY unless inside_a_frame?
        frame_window_calculator.frame_window(driver.frame_chain)
      end

      def inside_a_frame?
        !driver.frame_chain.empty?
      end

      def frame_window_calculator
        return FirefoxFrameWindowCalculator if driver.browser.running_browser_name == :firefox
        FrameWindowCalculator
      end

      module FrameWindowCalculator
        extend self
        def frame_window(frame_chain)
          chain = Applitools::Selenium::FrameChain.new other: frame_chain
          window = nil
          frames_offset = Applitools::Location.new(0,0)
          chain.map(&:dup).each do |frame|
            frames_offset = frame.location.offset(frames_offset).offset_negative(frame.parent_scroll_position)
            unless window
              window = Applitools::Region.from_location_size(frame.location, frame.size)
            else
              window.intersect(Applitools::Region.from_location_size(frame.location, frame.size))
            end
            #exception if empty window
          end
          window
        end
      end

      module FirefoxFrameWindowCalculator
        extend self
        def frame_window(_frame_chain)
          Applitools::Region::EMPTY
        end
      end
    end
  end
end