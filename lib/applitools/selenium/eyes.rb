# frozen_string_literal: false

module Applitools::Selenium
  # The main API gateway for the SDK
  class Eyes < Applitools::EyesBase
    # @!visibility private
    UNKNOWN_DEVICE_PIXEL_RATIO = 0

    # The pixel ratio will be used if detection of device pixel ratio is failed
    DEFAULT_DEVICE_PIXEL_RATIO = 1

    DEFAULT_WAIT_BEFORE_SCREENSHOTS = 0.1 # Seconds

    USE_DEFAULT_MATCH_TIMEOUT = -1

    DEFAULT_STITCHING_OVERLAP = 50 # Pixels

    extend Forwardable
    # @!visibility public

    class << self
      def eyes_driver(driver, eyes = nil)
        if driver.respond_to? :driver_for_eyes
          driver.driver_for_eyes eyes
        elsif defined?(::Capybara::Poltergeist) && (driver.is_a? ::Capybara::Poltergeist::Driver)
          Applitools::Poltergeist::Driver.new(eyes, driver: driver)
        else
          unless driver.is_a?(Applitools::Selenium::Driver)
            Applitools::EyesLogger.warn("Unrecognized driver type: (#{driver.class.name})!")
            is_mobile_device = driver.respond_to?(:capabilities) && driver.capabilities['platformName']
            Applitools::Selenium::Driver.new(eyes, driver: driver, is_mobile_device: is_mobile_device)
          end
          raise Applitools::EyesError.new "Unknown driver #{driver}!"
        end
      end

      # Set the viewport size.
      #
      # @param [Applitools::Selenium::Driver] driver The driver instance.
      # @param [Hash] viewport_size The required browser's viewport size.
      def set_viewport_size(driver, viewport_size)
        Applitools::ArgumentGuard.not_nil(driver, 'Driver')
        Applitools::ArgumentGuard.not_nil(viewport_size, 'viewport_size')
        Applitools::ArgumentGuard.is_a?(viewport_size, 'viewport_size', Applitools::RectangleSize)
        begin
          Applitools::Utils::EyesSeleniumUtils.set_viewport_size eyes_driver(driver), viewport_size
        rescue => e
          Applitools::EyesLogger.error e.class
          Applitools::EyesLogger.error e.message
          raise Applitools::EyesError.new 'Failed to set viewport size!'
        end
      end
    end

    # @!attribute [rw] force_full_page_screenshot
    #   Forces a full page screenshot (by scrolling and stitching) if the
    #   browser only supports viewport screenshots.
    #   @return [boolean] force full page screenshot flag
    # @!attribute [rw] wait_before_screenshots
    #   Sets the time to wait just before taking a screenshot (e.g., to allow
    #   positioning to stabilize when performing a full page stitching).
    #   @return [Float] The time to wait (Seconds). Values
    #     smaller or equal to 0, will cause the default value to be used.
    # @!attribute [rw] hide_scrollbars
    #   Turns on/off hiding scrollbars before taking a screenshot
    #   @return [boolean] hide_scrollbars flag
    # @!attribute [rw] scroll_to_region
    #   If set to +true+ browser will scroll to specified region (even it is out of viewport window)
    #     when check_region is called
    #   @return [boolean] scroll_to_region flag
    # @!attribute [rw] stitch_mode
    #   May be set to :CSS or :SCROLL (:SCROLL is default).
    #   When :CSS - SDK will use CSS transitions to perform scrolling, otherwise it will use Javascript
    #   window.scroll_to() function for scrolling purposes
    #   @return [boolean] stitch_mode (:CSS or :SCROLL)
    # @!attribute [Applitools::RectangleSize] explicit_entire_size
    #   May be set to an Applitools::RectangleSize instance or +nil+ (default).
    #   @return [Applitools::RectangleSize] explicit_entire_size

    attr_accessor :base_agent_id, :screenshot, :force_full_page_screenshot, :hide_scrollbars,
      :wait_before_screenshots, :debug_screenshot, :stitch_mode, :disable_horizontal_scrolling,
      :disable_vertical_scrolling, :explicit_entire_size, :debug_screenshot_provider, :stitching_overlap
    attr_reader :driver

    def_delegators 'Applitools::EyesLogger', :logger, :log_handler, :log_handler=

    # Creates a new (possibly disabled) Eyes instance that interacts with the
    # Eyes Server at the specified url.
    #
    # @param server_url The Eyes Server URL.
    def initialize(server_url = nil)
      super
      self.base_agent_id = "eyes.selenium.ruby/#{Applitools::VERSION}".freeze
      self.check_frame_or_element = false
      self.region_to_check = nil
      self.force_full_page_screenshot = false
      self.dont_get_title = false
      self.hide_scrollbars = false
      self.device_pixel_ratio = UNKNOWN_DEVICE_PIXEL_RATIO
      self.stitch_mode = Applitools::STITCH_MODE[:scroll]
      self.wait_before_screenshots = DEFAULT_WAIT_BEFORE_SCREENSHOTS
      self.region_visibility_strategy = MoveToRegionVisibilityStrategy.new
      self.debug_screenshot = false
      self.debug_screenshot_provider = Applitools::DebugScreenshotProvider.new
                                                                          .tag_access { tag_for_debug }
                                                                          .debug_flag_access { debug_screenshot }
      self.disable_horizontal_scrolling = false
      self.disable_vertical_scrolling = false
      self.explicit_entire_size = nil
      self.force_driver_resolution_as_viewport_size = false
      self.stitching_overlap = DEFAULT_STITCHING_OVERLAP
    end

    # Starts a test
    #
    # @param options [Hash] options
    # @option options :driver The driver that controls the browser hosting the application
    #   under the test. (*Required* option)
    # @option options [String] :app_name The name of the application under the test. (*Required* option)
    # @option options [String] :test_name The test name (*Required* option)
    # @option options [String | Hash] :viewport_size The required browser's viewport size
    #   (i.e., the visible part of the document's body) or +nil+ to use the current window's viewport.
    # @option options :session_type The type of the test (e.g., standard test / visual performance test).
    #   Default value is 'SEQUENTAL'
    # @return [Applitools::Selenium::Driver] A wrapped web driver which enables Eyes
    #   trigger recording and frame handling
    def open(options = {})
      original_driver = options.delete(:driver)
      options[:viewport_size] = Applitools::RectangleSize.from_any_argument options[:viewport_size] if
          options[:viewport_size]
      Applitools::ArgumentGuard.not_nil original_driver, 'options[:driver]'
      Applitools::ArgumentGuard.hash options, 'open(options)', [:app_name, :test_name]

      if disabled?
        logger.info('Ignored')
        return driver
      end

      @driver = self.class.eyes_driver(original_driver, self)
      perform_driver_specific_settings(original_driver)

      self.device_pixel_ratio = UNKNOWN_DEVICE_PIXEL_RATIO
      self.position_provider = self.class.position_provider(
        stitch_mode, driver, disable_horizontal_scrolling, disable_vertical_scrolling, explicit_entire_size
      )

      self.eyes_screenshot_factory = lambda do |image|
        Applitools::Selenium::EyesWebDriverScreenshot.new(
          image, driver: @driver, force_offset: position_provider.force_offset
        )
      end

      open_base(options) do
        self.viewport_size = nil if force_driver_resolution_as_viewport_size
        ensure_running_session
      end
      @driver
    end

    def perform_driver_specific_settings(original_driver)
      modifier = original_driver.class.to_s.downcase.gsub(/::/, '_')
      method_name = "perform_driver_settings_for_#{modifier}"
      send(method_name) if respond_to?(method_name, :include_private)
    end

    def perform_driver_settings_for_appium_driver
      self.region_visibility_strategy = NopRegionVisibilityStrategy.new
      self.force_driver_resolution_as_viewport_size = true
    end

    private :perform_driver_settings_for_appium_driver
    private :perform_driver_specific_settings

    # Sets the stitch mode.
    #
    # @param [Hash] value The desired type of stitching (:SCROLL is default).
    # @option value [Symbol] :css use Css to perform stitching.
    # @option value [Symbol] :scroll Scroll to perform stitching.
    # @return [Symbol] The type of stitching.
    def stitch_mode=(value)
      @stitch_mode = if value.to_s.upcase == Applitools::STITCH_MODE[:css].to_s
                       Applitools::STITCH_MODE[:css]
                     else
                       Applitools::STITCH_MODE[:scroll]
                     end
      unless driver.nil?
        self.position_provider = self.class.position_provider(
          stitch_mode, driver, disable_horizontal_scrolling, disable_vertical_scrolling, explicit_entire_size
        )
      end
      if stitch_mode == Applitools::STITCH_MODE[:css]
        @css_transition_original_hide_scrollbars = hide_scrollbars
        self.hide_scrollbars = true
      else
        self.hide_scrollbars = @css_transition_original_hide_scrollbars || false
      end
      value
    end

    # Takes a snapshot of the application under test and matches it with the expected output.
    #
    # @param [String] tag An optional tag to be assosiated with the snapshot.
    # @param [Fixnum] match_timeout The amount of time to retry matching (seconds)
    def check_window(tag = nil, match_timeout = USE_DEFAULT_MATCH_TIMEOUT)
      target = Applitools::Selenium::Target.window.tap do |t|
        t.timeout(match_timeout)
        t.fully if force_full_page_screenshot
      end
      check(tag, target)
    end

    # @!visibility private
    def title
      return driver.title unless dont_get_title
    rescue StandardError => e
      logger.warn "failed (#{e.message})"
      self.dont_get_title = false
      ''
    end

    # @!visibility private
    def get_viewport_size(web_driver = driver)
      Applitools::ArgumentGuard.not_nil 'web_driver', web_driver
      Applitools::Utils::EyesSeleniumUtils.extract_viewport_size(driver)
    end

    # Takes a snapshot and matches it with the expected output.
    #
    # @param [String] name The name of the tag.
    # @param [Applitools::Selenium::Target] target which area of the window to check.
    # @return [Applitools::MatchResult] The match results.
    def check(name, target)
      logger.info "check(#{name}) is called"
      self.tag_for_debug = name
      Applitools::ArgumentGuard.is_a? target, 'target', Applitools::Selenium::Target
      original_overflow = nil
      original_position_provider = position_provider
      original_force_full_page_screenshot = force_full_page_screenshot
      eyes_element = nil
      timeout = target.options[:timeout] || USE_DEFAULT_MATCH_TIMEOUT
      self.eyes_screenshot_factory = lambda do |image|
        Applitools::Selenium::EyesWebDriverScreenshot.new(
          image, driver: driver,
          force_offset: position_provider.force_offset,
          position_provider: self.class.position_provider(
            :SCROLL, driver, disable_horizontal_scrolling, disable_vertical_scrolling, explicit_entire_size
          )
        )
      end

      # rubocop:disable BlockLength
      check_in_frame target_frames: target.frames do
        begin
          match_data = Applitools::MatchWindowData.new
          match_data.tag = name
          update_default_settings(match_data)
          match_data.read_target(target, driver)
          eyes_element = target.region_to_check.call(driver)

          unless force_full_page_screenshot
            region_visibility_strategy.move_to_region original_position_provider,
              Applitools::Location.new(eyes_element.location.x.to_i, eyes_element.location.y.to_i)
          end

          check_window = false
          if !target.frames.empty? && eyes_element.is_a?(Applitools::Region)
            # check_current_frame
            logger.info "check_region_in_frame(#{eyes_element})"
            region_provider = region_provider_for_frame

          elsif eyes_element.is_a? Applitools::Selenium::Element
            # check_element
            logger.info 'check_region(' \
              "#{Applitools::Region.from_location_size(eyes_element.location, eyes_element.size)})"

            use_coordinates =
              if position_provider.is_a?(Applitools::Selenium::CssTranslatePositionProvider) &&
                  driver.frame_chain.empty?
                Applitools::EyesScreenshot::COORDINATE_TYPES[:context_as_is]
              else
                target.coordinate_type
              end

            stitch_region_provider = Applitools::RegionProvider.new(
              region_for_element(eyes_element), use_coordinates
            )

            region_provider = Applitools::RegionProvider.new(
                Applitools::Region.from_location_size(eyes_element.location, eyes_element.size), use_coordinates
            )

          else
            # check_window
            logger.info "check_window(match_timeout: #{timeout}, tag: #{match_data.tag})"
            region_provider = Applitools::RegionProvider.new(
              region_for_element(eyes_element),
              target.coordinate_type
            )
            check_window = true
          end

          if target.options[:stitch_content]
            check_window ? self.force_full_page_screenshot = true : self.check_frame_or_element = true
            if eyes_element.is_a? Applitools::Selenium::Element
              self.position_provider = Applitools::Selenium::ElementPositionProvider.new driver, eyes_element

              original_overflow = eyes_element.overflow
              eyes_element.overflow = 'hidden'
            end

            region_provider = Applitools::RegionProvider.new((stitch_region_provider || region_provider).region, target.coordinate_type)

            self.region_to_check = region_provider

            region_provider = Applitools::RegionProvider.new(
              Applitools::Region::EMPTY,
              nil
            )
          end

          check_window_base(
            region_provider, timeout, match_data
          )
        ensure
          eyes_element.overflow = original_overflow unless original_overflow.nil?
          self.check_frame_or_element = false
          self.force_full_page_screenshot = original_force_full_page_screenshot
          self.position_provider = original_position_provider
          self.region_to_check = nil
          region_visibility_strategy.return_to_original_position position_provider
        end
        # rubocop:enable BlockLength
      end
    end

    # Validates the contents of an iframe and matches it with the expected output.
    #
    # @param [Hash] options The specific parameters of the desired screenshot.
    # @option options [Array] :target_frames The frames to check.
    def check_in_frame(options)
      frames = options.delete :target_frames

      Applitools::ArgumentGuard.is_a? options, 'options', Hash
      Applitools::ArgumentGuard.is_a? frames, 'target_frames: []', Array

      return yield if block_given? && frames.empty?

      original_frame_chain = driver.frame_chain
      logger.info 'Switching to target frame according to frames path...'
      driver.switch_to.frames(frames_path: frames)
      logger.info 'Done!'

      yield if block_given?

      logger.info 'Switching back into top level frame...'
      driver.switch_to.default_content
      return unless original_frame_chain
      logger.info 'Switching back into original frame...'
      driver.switch_to.frames frame_chain: original_frame_chain
    end

    # Creates a region instance.
    #
    # @param [Applitools::Element] element The element.
    # @return [Applitools::Region] The relevant region.
    def region_for_element(element)
      return element if element.is_a? Applitools::Region

      p = element.location
      d = element.size

      border_left_width = element.border_left_width
      border_top_width = element.border_top_width
      border_right_width = element.border_right_width
      border_bottom_width = element.border_bottom_width

      Applitools::Region.new(
        p.x + border_left_width,
        p.y + border_top_width,
        d.width - border_left_width - border_right_width,
        d.height - border_top_width - border_bottom_width
      )
    end

    # Returns the region of a given iframe.
    #
    # @return [Applitools::Region] The region of the iframe.
    def region_provider_for_frame
      Object.new.tap do |provider|
        current_frame_size = lambda do
          frame_region = Applitools::Region.from_location_size(
            Applitools::Location.new(0, 0), driver.frame_chain!.current_frame.size
          )
          begin
            frame_region.intersect Applitools::Region.from_location_size(
              Applitools::Location.new(0, 0),
              Applitools::Utils::EyesSeleniumUtils.entire_page_size(driver)
            )
            frame_region
          ensure
            frame_region
          end
        end

        provider.instance_eval do
          define_singleton_method :region do
            current_frame_size.call
          end
          define_singleton_method :coordinate_type do
            Applitools::EyesScreenshot::COORDINATE_TYPES[:context_relative]
          end
        end
      end
    end

    private :check_in_frame
    private :region_for_element

    # Takes a snapshot of the application under test and matches a region of
    # a specific element with the expected region output.
    #
    # @param [Applitools::Selenium::Element] element Represents a region to check.
    # @param [Symbol] how a finder, such :css or :id. Selects a finder will be used to find an element
    #   See Selenium::Webdriver::Element#find_element documentation for full list of possible finders.
    # @param [String] what The value will be passed to a specified finder. If finder is :css it must be a css selector.
    # @param [Hash] options
    # @option options [String] :tag An optional tag to be associated with the snapshot.
    # @option options [Fixnum] :match_timeout The amount of time to retry matching. (Seconds)
    # @option options [Boolean] :stitch_content If set to true, will try to get full content of the element
    #   (including hidden content due overflow settings) by scrolling the element,
    #   taking and stitching partial screenshots.
    # @example Check region by element
    #   check_region(element, tag: 'Check a region by element', match_timeout: 3, stitch_content: false)
    # @example Check region by css selector
    #   check_region(:css, '.form-row .input#e_mail', tag: 'Check a region by element', match_timeout: 3,
    #   stitch_content: false)
    # @!parse def check_region(element, how=nil, what=nil, options = {}); end
    def check_region(*args)
      options = { timeout: USE_DEFAULT_MATCH_TIMEOUT, tag: nil }.merge! Applitools::Utils.extract_options!(args)
      target = Applitools::Selenium::Target.new.region(*args).timeout(options[:match_timeout])
      target.fully if options[:stitch_content]
      check(options[:tag], target)
    end

    # Validates the contents of an iframe and matches it with the expected output.
    #
    # @param [Hash] options The specific parameters of the desired screenshot.
    # @option options [Fixnum] :timeout The amount of time to retry matching. (Seconds)
    # @option options [String] :tag An optional tag to be associated with the snapshot.
    # @option options [String] :frame Frame element or frame name or frame id.
    # @option options [String] :name_or_id The name or id of the target frame (deprecated. use :frame instead).
    # @option options [String] :frame_element The frame element (deprecated. use :frame instead).
    # @return [Applitools::MatchResult] The match results.

    def check_frame(options = {})
      options = { timeout: USE_DEFAULT_MATCH_TIMEOUT, tag: nil }.merge!(options)
      frame = options[:frame] || options[:frame_element] || options[:name_or_id]
      target = Applitools::Selenium::Target.frame(frame).timeout(options[:timeout]).fully
      check(options[:tag], target)
    end

    # Validates the contents of a region in an iframe and matches it with the expected output.
    #
    # @param [Hash] options The specific parameters of the desired screenshot.
    # @option options [String] :name_or_id The name or id of the target frame (deprecated. use :frame instead).
    # @option options [String] :frame_element The frame element (deprecated. use :frame instead).
    # @option options [String] :frame Frame element or frame name or frame id.
    # @option options [String] :tag An optional tag to be associated with the snapshot.
    # @option options [Symbol] :by By which identifier to find the region (e.g :css, :id).
    # @option options [Fixnum] :timeout The amount of time to retry matching. (Seconds)
    # @option options [Boolean] :stitch_content Whether to stitch the content or not.
    # @return [Applitools::MatchResult] The match results.
    def check_region_in_frame(options = {})
      options = { timeout: USE_DEFAULT_MATCH_TIMEOUT, tag: nil, stitch_content: false }.merge!(options)
      Applitools::ArgumentGuard.not_nil options[:by], 'options[:by]'
      Applitools::ArgumentGuard.is_a? options[:by], 'options[:by]', Array

      how_what = options.delete(:by)
      frame = options[:frame] || options[:frame_element] || options[:name_or_id]

      target = Applitools::Selenium::Target.new.timeout(options[:timeout])
      target.frame(frame) if frame
      target.fully if options[:stitch_content]
      target.region(*how_what)

      check(options[:tag], target)
    end

    # Use this method to perform seamless testing with selenium through eyes driver.
    # It yields a block and passes to it an Applitools::Selenium::Driver instance, which wraps standard driver.
    # Using Selenium methods inside the 'test' block will send the messages to Selenium
    # after creating the Eyes triggers for them. Options are similar to {open}
    # @yieldparam driver [Applitools::Selenium::Driver] Gives a driver to a block, which translates calls to a native
    #   Selemium::Driver instance
    # @example
    #   eyes.test(app_name: 'my app', test_name: 'my test') do |driver|
    #      driver.get "http://www.google.com"
    #      driver.check_window("initial")
    #   end
    def test(options = {}, &_block)
      open(options)
      yield(driver)
      close
    ensure
      abort_if_not_closed
    end

    # @!visibility private
    def scroll_to_region
      region_visibility_strategy.is_a? Applitools::Selenium::MoveToRegionVisibilityStrategy
    end

    # @!visibility private
    def scroll_to_region=(value)
      if value
        self.region_visibility_strategy = Applitools::Selenium::MoveToRegionVisibilityStrategy.new
      else
        self.region_visibility_strategy = Applitools::Selenium::NopRegionVisibilityStrategy.new
      end
    end

    private

    attr_accessor :check_frame_or_element, :region_to_check, :dont_get_title,
      :device_pixel_ratio, :position_provider, :scale_provider, :tag_for_debug,
      :region_visibility_strategy, :eyes_screenshot_factory, :force_driver_resolution_as_viewport_size

    def capture_screenshot
      image_provider = Applitools::Selenium::TakesScreenshotImageProvider.new driver,
        debug_screenshot_provider: debug_screenshot_provider
      logger.info 'Getting screenshot (capture_screenshot() has been invoked)'

      update_scaling_params

      if hide_scrollbars
        begin
          original_overflow = Applitools::Utils::EyesSeleniumUtils.hide_scrollbars driver
        rescue Applitools::EyesDriverOperationException => e
          logger.warn "Failed to hide scrollbars! Error: #{e.message}"
        end
      end

      begin
        if check_frame_or_element
          logger.info 'Check frame/element requested'
          algo = Applitools::Selenium::FullPageCaptureAlgorithm.new(
            debug_screenshot_provider: debug_screenshot_provider
          )

          entire_frame_or_element = algo.get_stitched_region(
            image_provider: image_provider,
            region_to_check: region_to_check,
            origin_provider: position_provider,
            position_provider: position_provider,
            scale_provider: scale_provider,
            cut_provider: cut_provider,
            wait_before_screenshots: wait_before_screenshots,
            eyes_screenshot_factory: eyes_screenshot_factory,
            stitching_overlap: stitching_overlap
          )

          logger.info 'Building screenshot object...'
          self.screenshot = Applitools::Selenium::EyesWebDriverScreenshot.new entire_frame_or_element,
            driver: driver,
            entire_frame_size: Applitools::RectangleSize.new(entire_frame_or_element.width,
              entire_frame_or_element.height)
        elsif force_full_page_screenshot
          logger.info 'Full page screenshot requested'
          original_frame = driver.frame_chain
          driver.switch_to.default_content
          algo = Applitools::Selenium::FullPageCaptureAlgorithm.new(
            debug_screenshot_provider: debug_screenshot_provider
          )
          region_provider = Object.new
          region_provider.instance_eval do
            def region
              Applitools::Region::EMPTY
            end

            def coordinate_type
              nil
            end
          end
          full_page_image = algo.get_stitched_region image_provider: image_provider,
                                  region_to_check: region_provider,
                                  origin_provider: Applitools::Selenium::ScrollPositionProvider.new(driver),
                                  position_provider: position_provider,
                                  scale_provider: scale_provider,
                                  cut_provider: cut_provider,
                                  wait_before_screenshots: wait_before_screenshots,
                                  eyes_screenshot_factory: eyes_screenshot_factory,
                                  stitching_overlap: stitching_overlap

          unless driver.frame_chain.empty?
            logger.info 'Switching back to original frame...'
            driver.switch_to.frame original_frame
            logger.info 'Done switching!'
          end
          logger.info 'Creating EyesWebDriver screenshot instance..'
          ewd_screenshot = Applitools::Selenium::EyesFullPageScreenshot.new(full_page_image)
          logger.info 'Done creating EyesWebDriver screenshot instance!'
          ewd_screenshot
        else
          logger.info 'Screenshot requested...'
          sleep wait_before_screenshots
          image = image_provider.take_screenshot
          scale_provider.scale_image(image) if scale_provider
          cut_provider.cut(image) if cut_provider
          self.screenshot = eyes_screenshot_factory.call(image)
        end
      ensure
        begin
          Applitools::Utils::EyesSeleniumUtils.set_overflow driver, original_overflow
        rescue Applitools::EyesDriverOperationException => e
          logger.warn "Failed to revert overflow! Error: #{e.message}"
        end
      end
    end

    def vp_size=(value, skip_check_if_open = false)
      raise Applitools::EyesNotOpenException.new 'set_viewport_size: Eyes not open!' unless skip_check_if_open || open?
      original_frame = driver.frame_chain
      driver.switch_to.default_content
      begin
        Applitools::Utils::EyesSeleniumUtils.set_viewport_size driver, value
      rescue => e
        logger.error e.class.to_s
        logger.error e.message
        raise Applitools::TestFailedError.new "#{e.class} - #{e.message}"
      ensure
        driver.switch_to.frames(frame_chain: original_frame)
      end
    end

    alias set_viewport_size vp_size=

    def get_driver(options)
      # TODO: remove the "browser" related block when possible. It's for backward compatibility.
      if options.key?(:browser)
        logger.warn('"browser" key is deprecated, please use "driver" instead.')
        return options[:browser]
      end

      options.fetch(:driver, nil)
    end

    def update_scaling_params
      return unless device_pixel_ratio == UNKNOWN_DEVICE_PIXEL_RATIO

      logger.info 'Trying to extract device pixel ratio...'
      begin
        self.device_pixel_ratio = Applitools::Utils::EyesSeleniumUtils.device_pixel_ratio(driver)
      rescue Applitools::EyesDriverOperationException
        logger.warn 'Failed to extract device pixel ratio! Using default.'
        self.device_pixel_ratio = DEFAULT_DEVICE_PIXEL_RATIO
      end

      logger.info "Device pixel_ratio: #{device_pixel_ratio}"
      logger.info 'Setting scale provider...'

      begin
        self.scale_provider = Applitools::Selenium::ContextBasedScaleProvider.new(position_provider.entire_size,
          viewport_size, device_pixel_ratio)
      rescue StandardError
        logger.info 'Failed to set ContextBasedScaleProvider'
        logger.info 'Using FixedScaleProvider instead'
        self.scale_provider = Applitools::FixedScaleProvider.new(1.to_f / device_pixel_ratio)
      end
      logger.info 'Done!'
    end

    def _add_text_trigger(control, text)
      unless last_screenshot
        logger.info "Ignoring #{text} (no screenshot)"
        return
      end

      unless driver.frame_chain.same_frame_chain? last_screenshot.frame_chain
        logger.info "Ignoring #{text} (different_frame)"
        return
      end

      add_text_trigger_base(control, text)
    end

    def add_text_trigger(control, text)
      if disabled?
        logger.info "Ignoring #{text} (disabled)"
        return
      end

      Applitools::ArgumentGuard.not_nil control, 'control'
      return _add_text_trigger(control, text) if control.is_a? Applitools::Region

      pl = control.location
      ds = control.size

      element_region = Applitools::Region.new(pl.x, pl.y, ds.width, ds.height)

      return _add_text_trigger(element_region, text) if control.is_a? Applitools::Selenium::Element
    end

    def add_mouse_trigger(mouse_action, element)
      if disabled?
        logger.info "Ignoring #{mouse_action} (disabled)"
        return
      end

      if element.is_a? Hash
        return add_mouse_trigger_by_region_and_location(mouse_action, element[:region], element[:location]) if
            element.key?(:location) && element.key?(:region)
        raise Applitools::EyesIllegalArgument.new 'Element[] doesn\'t contain required keys!'
      end

      Applitools::ArgumentGuard.not_nil element, 'element'
      Applitools::ArgumentGuard.is_a? element, 'element', Applitools::Selenium::Element

      pl = element.location
      ds = element.size

      element_region = Applitools::Region.new(pl.x, pl.y, ds.width, ds.height)

      unless last_screenshot
        logger.info "Ignoring #{mouse_action} (no screenshot)"
        return
      end

      unless driver.frame_chain.same_frame_chain? last_screenshot.frame_chain
        logger.info "Ignoring #{mouse_action} (different_frame)"
        return
      end

      add_mouse_trigger_base(mouse_action, element_region, element_region.middle_offset)
    end

    # control - Region
    # cursor - Location
    def add_mouse_trigger_by_region_and_location(mouse_action, control, cursor)
      unless last_screenshot
        logger.info "Ignoring #{mouse_action} (no screenshot)"
        return
      end

      Applitools::ArgumentGuard.is_a? control, 'control', Applitools::Region
      Applitools::ArgumentGuard.is_a? cursor, 'cursor', Applitools::Location

      if driver.frame_chain.same_frame_chain? last_screenshot.frame_chain
        logger.info "Ignoring #{mouse_action} (different_frame)"
        return
      end

      add_mouse_trigger_base(mouse_action, control, cursor)
    end

    public :add_text_trigger, :add_mouse_trigger, :add_mouse_trigger_by_region_and_location

    protected

    def check_current_frame(match_timeout, tag)
      logger.info "check_current_frame(#{match_timeout}, #{tag})"
      self.check_frame_or_element = true

      region_provider = Object.new.tap do |provider|
        provider.instance_eval do
          define_singleton_method :region do
            Applitools::Region::EMPTY
          end
          define_singleton_method :coordinate_type do
            nil
          end
        end
      end

      self.region_to_check = Object.new.tap do |provider|
        current_frame_size = lambda do
          frame_region = Applitools::Region.from_location_size(
            Applitools::Location.new(0, 0), driver.frame_chain!.current_frame.size
          )
          begin
            frame_region.intersect Applitools::Region.from_location_size(
              Applitools::Location.new(0, 0),
              Applitools::Utils::EyesSeleniumUtils.entire_page_size(driver)
            )
            frame_region
          ensure
            frame_region
          end
        end

        provider.instance_eval do
          define_singleton_method :region do
            current_frame_size.call
          end
          define_singleton_method :coordinate_type do
            Applitools::EyesScreenshot::COORDINATE_TYPES[:context_relative]
          end
        end
      end

      self.eyes_screenshot_factory = lambda do |image|
        Applitools::Selenium::EyesWebDriverScreenshot.new(
          image, driver: driver, force_offset: position_provider.force_offset
        )
      end

      match_data = Applitools::MatchWindowData.new.tap do |d|
        d.tag = tag
        d.ignore_mismatch = false
        d.match_level = default_match_settings[:match_level]
      end

      check_window_base region_provider, match_timeout, match_data
    end

    def app_environment
      app_env = super
      if app_env.os.nil?
        logger.info 'No OS set, checking for mobile OS...'
        underlying_driver = Applitools::Utils::EyesSeleniumUtils.mobile_device?
        unless underlying_driver.nil?
          logger.info 'Mobile device detected! Checking device type...'
          if Applitools::Utils::EyesSeleniumUtils.android?(underlying_driver)
            logger.info 'Android detected...'
            platform_name = 'Android'
          elsif Applitools::Utils::EyesSeleniumUtils.ios?(underlying_driver)
            logger.info 'iOS detected...'
            platform_name = 'iOS'
          else
            logger.info 'Unknown device type'
          end
        end

        if platform_name && !platform_name.empty?
          os = platform_name
          platform_version = Applitools::Utils::EyesSeleniumUtils.platform_version(underlying_driver).to_s
          unless platform_version.empty?
            major_version = platform_version.split(/\./).first
            os << " #{major_version}"
          end
          logger.info "Setting OS: #{os}"
          app_env.os = os
        end
      else
        logger.info 'No mobile OS detected.'
      end
      app_env
    end

    # check a region, specified by element_or_selector parameter
    #
    # @param [Array] element_or_selector Array, which contains Applitools::Selenium::Element or [:finder, :value]
    #    pair should be used in find_element
    # @param [Hash] options
    # @option options [String] :tag
    # @option options [Float] :tmatch_timeout
    def check_region_(element_or_selector, options = {})
      selector = element_or_selector if Applitools::Selenium::Driver::FINDERS.keys.include? element_or_selector.first
      element = element_or_selector.first if element_or_selector.first.instance_of? Applitools::Selenium::Element
      element = driver.find_element(*selector) unless element
      raise Applitools::EyesIllegalArgument.new 'You should pass :selector or :element!' unless element

      if !options[:tag].nil? && !options[:tag].empty?
        tag = options[:tag]
        self.tag_for_debug = tag
      end

      match_timeout = options[:match_timeout] || USE_DEFAULT_MATCH_TIMEOUT

      logger.info "check_region(element, #{match_timeout}, #{tag}): Ignored" && return if disabled?
      Applitools::ArgumentGuard.not_nil 'options[:element]', element
      logger.info "check_region(element: element, #{match_timeout}, #{tag})"

      location_as_point = element.location
      region_visibility_strategy.move_to_region position_provider,
        Applitools::Location.new(location_as_point.x.to_i, location_as_point.y.to_i)

      region_provider = Object.new.tap do |prov|
        prov.instance_eval do
          define_singleton_method :region do
            p = element.location
            d = element.size
            Applitools::Region.from_location_size p, d
          end

          define_singleton_method :coordinate_type do
            Applitools::EyesScreenshot::COORDINATE_TYPES[:context_relative]
          end
        end
      end

      self.eyes_screenshot_factory = lambda do |image|
        Applitools::Selenium::EyesWebDriverScreenshot.new(image, driver: driver)
      end

      match_data = Applitools::MatchWindowData.new.tap do |d|
        d.tag = tag
        d.ignore_mismatch = false
        d.match_level = default_match_settings[:match_level]
      end

      result = check_window_base(
        region_provider, match_timeout, match_data
      )

      logger.info 'Done! trying to scroll back to original position...'
      region_visibility_strategy.return_to_original_position position_provider
      logger.info 'Done!'
      result
    end

    # Checks an element, specified by +element_or_selector+ parameter
    #
    # @param [Array] element_or_selector Array, which contains Applitools::Selenium::Element or [:finder, :value]
    #    pair should be used in find_element
    # @param [Hash] options
    # @option options [String] :tag
    # @option options [Float] :match_timeout

    def check_element(element_or_selector, options = {})
      selector = element_or_selector if Applitools::Selenium::Driver::FINDERS.keys.include? element_or_selector.first
      if !options[:tag].nil? && !options[:tag].empty?
        tag = options[:tag]
        self.tag_for_debug = tag
      end
      match_timeout = options[:match_timeout] || USE_DEFAULT_MATCH_TIMEOUT

      if disabled?
        logger.info "check_element(#{options.inject([]) { |res, (k, v)| res << "#{k}: #{v}" }.join(', ')}):" /
          ' Ignored'
        return
      end

      eyes_element = element_or_selector.first if element_or_selector.first.instance_of? Applitools::Selenium::Element
      eyes_element = driver.find_element(*selector) unless eyes_element
      raise Applitools::EyesIllegalArgument.new 'You should pass :selector or :element!' unless eyes_element
      eyes_element = Applitools::Selenium::Element.new(driver, eyes_element) unless
         eyes_element.is_a? Applitools::Selenium::Element

      location_as_point = eyes_element.location
      region_visibility_strategy.move_to_region position_provider,
        Applitools::Location.new(location_as_point.x.to_i, location_as_point.y.to_i)

      original_overflow = nil
      original_position_provider = position_provider

      begin
        self.check_frame_or_element = true
        self.position_provider = Applitools::Selenium::ElementPositionProvider.new driver, eyes_element
        original_overflow = eyes_element.overflow
        eyes_element.overflow = 'hidden'

        p = eyes_element.location
        d = eyes_element.size

        border_left_width = eyes_element.border_left_width
        border_top_width = eyes_element.border_top_width
        border_right_width = eyes_element.border_right_width
        border_bottom_width = eyes_element.border_bottom_width

        element_region = Applitools::Region.new(
          p.x + border_left_width,
          p.y + border_top_width,
          d.width - border_left_width - border_right_width,
          d.height - border_top_width - border_bottom_width
        )

        logger.info "Element region: #{element_region}"

        self.region_to_check = Object.new.tap do |prov|
          prov.instance_eval do
            define_singleton_method :region do
              element_region
            end

            define_singleton_method :coordinate_type do
              Applitools::EyesScreenshot::COORDINATE_TYPES[:context_relative]
            end
          end
        end

        base_check_region_provider = Object.new.tap do |prov|
          prov.instance_eval do
            define_singleton_method :region do
              Applitools::Region::EMPTY
            end

            define_singleton_method :coordinate_type do
              nil
            end
          end
        end

        self.eyes_screenshot_factory = lambda do |image|
          Applitools::Selenium::EyesWebDriverScreenshot.new(
            image, driver: driver, force_offset: position_provider.state
          )
        end

        match_data = Applitools::MatchWindowData.new.tap do |data|
          data.tag = tag
          data.ignore_mismatch = false
          data.match_level = default_match_settings[:match_level]
        end

        check_window_base(
          base_check_region_provider, match_timeout, match_data
        )
      ensure
        eyes_element.overflow = original_overflow unless original_overflow.nil?
        self.check_frame_or_element = false
        self.position_provider = original_position_provider
        self.region_to_check = nil

        region_visibility_strategy.return_to_original_position position_provider
      end
    end

    def inferred_environment
      return @inferred_environment unless @inferred_environment.nil?

      user_agent = driver.user_agent
      return "useragent: #{user_agent}" if user_agent && !user_agent.empty?

      nil
    end

    class << self
      def position_provider(stitch_mode, driver, disable_horizontal = false, disable_vertical = false,
        explicit_entire_size = nil)

        max_width = nil
        max_height = nil
        unless explicit_entire_size.nil?
          max_width = explicit_entire_size.width
          max_height = explicit_entire_size.height
        end
        case stitch_mode
        when :SCROLL
          Applitools::Selenium::ScrollPositionProvider.new(driver, disable_horizontal, disable_vertical,
            max_width, max_height)
        when :CSS
          Applitools::Selenium::CssTranslatePositionProvider.new(driver, disable_horizontal, disable_vertical,
            max_width, max_height)
        end
      end
    end
  end
end
